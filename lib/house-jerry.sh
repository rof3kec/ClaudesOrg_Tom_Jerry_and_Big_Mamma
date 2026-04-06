#!/usr/bin/env bash
# lib/house-jerry.sh — Jerry (parallel worker) management for Big Mamma
#
# Sourced by claude-supervisor.sh. Requires house-common.sh loaded first.
#
# Globals read:  MAX_PARALLEL, TASK_FILE, AUTO_MODE, MAMMA_INSTRUCTIONS,
#                VERBOSE_LOG, BRANCH, PENDING
# Globals write: P_PIDS[], P_WORKTREES[], P_BRANCHES[], P_TASK_LINES[],
#                P_TASK_DESCS[], P_ACTIVE[], PARALLEL_LAST_ANALYSIS,
#                PENDING_COMMIT, LAST_CHANGE_TIME

# Guard against double-sourcing
[[ -n "${_HOUSE_JERRY_LOADED:-}" ]] && return 0
_HOUSE_JERRY_LOADED=1

# ─── Jerry Specs File ──────────────────────────────────────────────────────

JERRY_SPECS_FILE=".house-jerry-specs.json"

# ─── Array State (initialized by supervisor before sourcing) ───────────────
# P_PIDS[], P_WORKTREES[], P_BRANCHES[], P_TASK_LINES[],
# P_TASK_DESCS[], P_ACTIVE[] — must be pre-allocated by caller.

# ─── Slot Management ──────────────────────────────────────────────────────

count_active_parallel() {
  local count=0
  for ((i=0; i<MAX_PARALLEL; i++)); do
    [ "${P_ACTIVE[$i]}" = true ] && count=$((count + 1))
  done
  echo "$count"
}

find_free_slot() {
  for ((i=0; i<MAX_PARALLEL; i++)); do
    [ "${P_ACTIVE[$i]}" = false ] && echo "$i" && return 0
  done
  return 1
}

any_parallel_active() {
  for ((i=0; i<MAX_PARALLEL; i++)); do
    [ "${P_ACTIVE[$i]}" = true ] && return 0
  done
  return 1
}

# ─── Jerry Specializations ─────────────────────────────────────────────────

# Read specialization for a Jerry slot (returns "fullstack" if not set)
read_jerry_spec() {
  local slot="$1"
  if [ ! -f "$JERRY_SPECS_FILE" ]; then
    echo "fullstack"
    return
  fi
  local spec
  spec=$(grep -o "\"$slot\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$JERRY_SPECS_FILE" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')
  echo "${spec:-fullstack}"
}

# Get the role prompt for a specialization
get_spec_prompt() {
  local spec="$1"
  case "$spec" in
    architect)
      echo "ROLE: You are a System Architect. Focus on high-level design, project structure, module organization, dependency management, and architectural patterns. Prioritize clean abstractions, separation of concerns, and scalable solutions." ;;
    backend)
      echo "ROLE: You are a Backend Engineer. Focus on APIs, server logic, services, request handling, middleware, authentication, and business logic. Prioritize correctness, performance, and clean interfaces." ;;
    frontend)
      echo "ROLE: You are a Frontend Engineer. Focus on UI components, styling, layout, user interactions, accessibility, and responsive design. Prioritize user experience and visual polish." ;;
    data)
      echo "ROLE: You are a Data Layer Engineer. Focus on data models, database schemas, migrations, ORMs, queries, caching, and data integrity. Prioritize data consistency and efficient access patterns." ;;
    platform)
      echo "ROLE: You are a Platform Engineer. Focus on CI/CD pipelines, Docker, infrastructure, deployment, monitoring, and DevOps. Prioritize reliability, automation, and operational excellence." ;;
    qa)
      echo "ROLE: You are a QA Engineer. Focus on writing tests, test automation, test coverage, edge cases, and quality assurance. Prioritize thorough testing and catching bugs early." ;;
    design)
      echo "ROLE: You are a Design System Engineer. Focus on design tokens, reusable UI components, theming, typography, color systems, and consistent visual language. Prioritize consistency and reusability." ;;
    *)
      echo "" ;;  # fullstack — no special role prompt
  esac
}

# Get keywords for matching tasks to specializations
get_spec_keywords() {
  local spec="$1"
  case "$spec" in
    architect) echo "architect design structure refactor pattern module dependency organize" ;;
    backend) echo "api server endpoint route handler middleware auth service backend database query" ;;
    frontend) echo "ui component style css html layout render view page frontend react vue" ;;
    data) echo "data model schema migration database db query orm table column index cache" ;;
    platform) echo "ci cd pipeline docker deploy infra terraform kubernetes helm monitoring" ;;
    qa) echo "test spec assert coverage unit integration e2e mock fixture quality" ;;
    design) echo "design token theme color typography font spacing component library system" ;;
    *) echo "" ;;
  esac
}

# Check if a task description matches a specialization's keywords
task_matches_spec() {
  local task_desc="$1"
  local spec="$2"
  local keywords
  keywords=$(get_spec_keywords "$spec")
  [ -z "$keywords" ] && return 1  # fullstack matches nothing specifically
  local task_lower
  task_lower=$(echo "$task_desc" | tr '[:upper:]' '[:lower:]')
  for kw in $keywords; do
    if echo "$task_lower" | grep -qiw "$kw"; then
      return 0
    fi
  done
  return 1
}

# ─── Fill Jerry Slots ──────────────────────────────────────────────────────

fill_jerry_slots() {
  # Eagerly fill free Jerry slots with pending tasks — instant, no LLM analysis.
  local free_slots=0
  for ((i=0; i<MAX_PARALLEL; i++)); do
    [ "${P_ACTIVE[$i]}" = false ] && free_slots=$((free_slots + 1))
  done
  [ "$free_slots" -eq 0 ] && return 1
  [ "$PENDING" -lt 1 ] && return 1

  # Cooldown: don't re-scan if we just deployed
  local now_ts
  now_ts=$(date +%s)
  if [ $((now_ts - PARALLEL_LAST_ANALYSIS)) -lt 10 ]; then
    return 1
  fi

  # Find active section (section-aware delegation)
  local sep_line
  sep_line=$(grep -n '^_{5,}' "$TASK_FILE" 2>/dev/null | head -1 | cut -d: -f1)
  sep_line="${sep_line:-0}"

  if ! find_active_section "$TASK_FILE" "$sep_line"; then
    return 1
  fi

  house_log "👩🏽🐭 Pending task(s) in '$ACTIVE_SECTION_NAME', $free_slots Jerry slot(s) free — filling them up!"

  # Reserve first pending task for Tom (unless Tom is already busy)
  local skip_first=1
  if is_claude_alive; then
    skip_first=0  # Tom is busy — Jerry can take everything
  fi

  # Collect candidate tasks (with continuation lines)
  local -a CAND_LINES=()
  local -a CAND_DESCS=()
  local skipped=0
  while IFS= read -r candidate; do
    local line_num
    line_num=$(echo "$candidate" | cut -d: -f1)
    [ "$line_num" -lt "$ACTIVE_SECTION_START" ] && continue
    [ "$line_num" -gt "$ACTIVE_SECTION_END" ] && break

    # Leave first pending task for Tom's sequential queue
    if [ "$skip_first" -gt 0 ] && [ "$skipped" -lt "$skip_first" ]; then
      skipped=$((skipped + 1))
      continue
    fi

    local task_desc
    task_desc=$(echo "$candidate" | sed 's/^[0-9]*:\[ \] //')

    # Read continuation lines (multi-line task descriptions)
    local _cnext=$(( line_num + 1 ))
    while [ "$_cnext" -le "$ACTIVE_SECTION_END" ]; do
      local _ccont
      _ccont=$(sed -n "${_cnext}p" "$TASK_FILE")
      if [ -z "$_ccont" ] || echo "$_ccont" | grep -qE '^\[[ xXqQ!-]\] |^#+ |^_{5,}'; then
        break
      fi
      task_desc="${task_desc}
${_ccont}"
      _cnext=$((_cnext + 1))
    done

    # Skip status-like lines that aren't real tasks
    if echo "$task_desc" | grep -qiE '^(pending|done|in progress|failed|waiting)(\s|$)'; then
      continue
    fi

    CAND_LINES+=("$line_num")
    CAND_DESCS+=("$task_desc")
  done < <(grep -n '^\[ \] ' "$TASK_FILE" 2>/dev/null || true)

  [ ${#CAND_LINES[@]} -eq 0 ] && { PARALLEL_LAST_ANALYSIS=$now_ts; return 1; }

  # Track which tasks have been assigned
  local -a task_used=()
  for ((i=0; i<${#CAND_LINES[@]}; i++)); do task_used+=(false); done

  local spawned=0

  # Pass 1: Match specialized Jerrys to tasks matching their expertise
  for ((si=0; si<MAX_PARALLEL; si++)); do
    [ "${P_ACTIVE[$si]}" = true ] && continue
    local spec
    spec=$(read_jerry_spec "$si")
    [ "$spec" = "fullstack" ] && continue

    for ((ti=0; ti<${#CAND_LINES[@]}; ti++)); do
      [ "${task_used[$ti]}" = true ] && continue
      if task_matches_spec "${CAND_DESCS[$ti]}" "$spec"; then
        spawn_parallel_worker "$si" "${CAND_LINES[$ti]}" "${CAND_DESCS[$ti]}"
        if [ "${P_ACTIVE[$si]}" = true ]; then
          task_used[$ti]=true
          spawned=$((spawned + 1))
          house_log "   👩🏽🎯 Matched Jerry #$si ($spec) to task #${CAND_LINES[$ti]}"
        fi
        break
      fi
    done
  done

  # Pass 2: Fill remaining free slots with any unassigned task
  for ((si=0; si<MAX_PARALLEL; si++)); do
    [ "${P_ACTIVE[$si]}" = true ] && continue

    for ((ti=0; ti<${#CAND_LINES[@]}; ti++)); do
      [ "${task_used[$ti]}" = true ] && continue

      spawn_parallel_worker "$si" "${CAND_LINES[$ti]}" "${CAND_DESCS[$ti]}"
      if [ "${P_ACTIVE[$si]}" = true ]; then
        task_used[$ti]=true
        spawned=$((spawned + 1))
      else
        house_log "🐭⚠ Jerry #$si failed to launch for line ${CAND_LINES[$ti]} — slot still free, trying next task"
        continue
      fi
      break
    done
  done

  PARALLEL_LAST_ANALYSIS=$now_ts

  if [ "$spawned" -gt 0 ]; then
    house_log "👩🏽🐭 Deployed $spawned Jerry(s)! \"Y'all better WORK, not just STAND there!\""
  fi
  return 0
}

# ─── Spawn a Jerry ──────────────────────────────────────────────────────────

spawn_parallel_worker() {
  local slot="$1"
  local task_line="$2"
  local task_desc="$3"
  local branch_name="parallel-${slot}-$(date +%s)"
  local worktree_dir=".worktrees/$branch_name"
  local status_file=".parallel-status-$slot"
  local log_file="claude-parallel-$slot.log"

  house_log "${_C_BLUE}▶ TASK STARTED ─── [Jerry #${slot}] #${task_line}: ${task_desc}${_C_RST}"

  # Mark task as in-progress (with race-condition guard)
  lock_tasks
  sedi "${task_line}s/^\[ \] /[!] /" "$TASK_FILE"
  # Verify the mark stuck
  local verify
  verify=$(sed -n "${task_line}p" "$TASK_FILE" 2>/dev/null)
  if ! echo "$verify" | grep -q '^\[!\] '; then
    unlock_tasks
    house_log "🐭⚠ Jerry #$slot: task at line $task_line already claimed. Skipping."
    return
  fi
  unlock_tasks

  # Create worktree (Jerry's hideout)
  mkdir -p .worktrees
  if ! git worktree add "$worktree_dir" -b "$branch_name" >> "$VERBOSE_LOG" 2>&1; then
    house_log "🐭💥 Jerry #$slot couldn't dig his tunnel (worktree failed). Reverting task."
    lock_tasks
    sedi "${task_line}s/^\[!\] /[ ] /" "$TASK_FILE"
    unlock_tasks
    return
  fi

  # Read specialization for this slot
  local jerry_spec
  jerry_spec=$(read_jerry_spec "$slot")

  # Write Jerry's status (flatten desc for KEY=VALUE format)
  local safe_desc="${task_desc//$'\n'/ }"
  cat > "$status_file" <<EOF
STATE=running
SLOT=$slot
TASK_LINE=$task_line
TASK_DESC=$safe_desc
SPEC=$jerry_spec
BRANCH=$branch_name
WORKTREE=$worktree_dir
STARTED=$(date +%s)
UPDATED=$(date +%s)
EOF

  # Build command
  CLAUDE_SPAWN="claude -p"
  [ "$AUTO_MODE" = "--auto" ] && CLAUDE_SPAWN="$CLAUDE_SPAWN --dangerously-skip-permissions"

  # Build context for Jerry
  JERRY_CONTEXT=""
  if [ -n "$MAMMA_INSTRUCTIONS" ]; then
    JERRY_CONTEXT="

Project context: $MAMMA_INSTRUCTIONS"
  fi

  # Add specialization role prompt
  local spec_prompt
  spec_prompt=$(get_spec_prompt "$jerry_spec")
  if [ -n "$spec_prompt" ]; then
    JERRY_CONTEXT="${JERRY_CONTEXT}

$spec_prompt"
    house_log "   🐭🎓 Jerry #$slot role: $jerry_spec"
  fi

  # Spawn Claude in Jerry's hideout (worktree)
  (cd "$worktree_dir" && $CLAUDE_SPAWN "$task_desc
${JERRY_CONTEXT}
(IMPORTANT: You are running in an isolated git worktree. Edit files only — do NOT run build, test, or install commands like pnpm install, tsc, etc. A QA worker will verify your changes after merge.)" >> "../../$log_file" 2>&1) &

  P_PIDS[$slot]=$!
  P_TASK_LINES[$slot]="$task_line"
  P_TASK_DESCS[$slot]="$task_desc"
  P_WORKTREES[$slot]="$worktree_dir"
  P_BRANCHES[$slot]="$branch_name"
  P_ACTIVE[$slot]=true

  house_log "   🐭 Jerry #$slot scurrying away (PID ${P_PIDS[$slot]}) in $worktree_dir"
}

# ─── Check Jerry Workers ────────────────────────────────────────────────────

check_parallel_workers() {
  for ((i=0; i<MAX_PARALLEL; i++)); do
    [ "${P_ACTIVE[$i]}" = true ] || continue

    if is_process_alive "${P_PIDS[$i]}"; then
      # Still running — periodic status
      local status_file=".parallel-status-$i"
      if [ -f "$status_file" ]; then
        # Heartbeat
        sedi "s/^UPDATED=.*/UPDATED=$(date +%s)/" "$status_file" 2>/dev/null
        local p_started
        p_started=$(grep '^STARTED=' "$status_file" 2>/dev/null | cut -d= -f2)
        if [ -n "$p_started" ]; then
          local p_age=$(( $(date +%s) - p_started ))
          local p_age_str="${p_age}s"
          [ "$p_age" -gt 60 ] && p_age_str="$((p_age / 60))m$((p_age % 60))s"
          if [ $((ALIVE_TICKS % 4)) -eq 0 ] && [ "$ALIVE_TICKS" -gt 0 ]; then
            house_log "🐭 Jerry #$i still scurrying (${p_age_str}): $(short "${P_TASK_DESCS[$i]}")"
          fi
        fi
      fi
      continue
    fi

    # Jerry finished his mission
    wait "${P_PIDS[$i]}" 2>/dev/null
    local p_exit=$?

    if [ "$p_exit" -eq 0 ]; then
      house_log "${_C_GREEN}✓ TASK DONE ─── [Jerry #${i}] #${P_TASK_LINES[$i]}: ${P_TASK_DESCS[$i]}${_C_RST}"
      merge_parallel_worker "$i"
    else
      house_log "${_C_RED}✗ TASK FAILED ─── [Jerry #${i}] #${P_TASK_LINES[$i]} (exit $p_exit): ${P_TASK_DESCS[$i]}${_C_RST}"
      lock_tasks
      local tl="${P_TASK_LINES[$i]}"
      sedi "${tl}s/^\[!\] /[ ] /" "$TASK_FILE"
      unlock_tasks
      cleanup_parallel_slot "$i"
    fi
  done
}

# ─── Merge Jerry's Work ─────────────────────────────────────────────────────

merge_parallel_worker() {
  local slot="$1"
  local branch="${P_BRANCHES[$slot]}"
  local task_line="${P_TASK_LINES[$slot]}"

  house_log "🐭🔀 Bringing Jerry #$slot's work home (merging branch $branch)..."

  # Commit any uncommitted changes from Tom first
  if has_changes; then
    house_log "   Committing Tom's work-in-progress before merge..."
    git add -A 2>/dev/null
    git commit -m "auto: work in progress (pre-parallel-merge)" >> "$VERBOSE_LOG" 2>&1 || true
  fi

  if git merge "$branch" --no-edit >> "$VERBOSE_LOG" 2>&1; then
    house_log "🐭✓ Jerry #$slot's work merged clean! That mouse is GOOD."

    # Mark task as ready for QA (Spike will promote to [x])
    lock_tasks
    sedi "${task_line}s/^\[!\] /[q] /" "$TASK_FILE"
    unlock_tasks

    PENDING_COMMIT=true
    LAST_CHANGE_TIME=$(date +%s)
  else
    house_log "🐭⚠ Jerry #$slot's work COLLIDED with Tom's! Merge conflict!"
    house_log "   \"Same old story...\" Re-queuing for Tom to handle sequentially."
    git merge --abort >> "$VERBOSE_LOG" 2>&1 || true

    lock_tasks
    sedi "${task_line}s/^\[!\] /[ ] /" "$TASK_FILE"
    unlock_tasks
  fi

  cleanup_parallel_slot "$slot"
}

# ─── Cleanup Slot ────────────────────────────────────────────────────────────

cleanup_parallel_slot() {
  local slot="$1"
  local worktree="${P_WORKTREES[$slot]}"
  local branch="${P_BRANCHES[$slot]}"
  local status_file=".parallel-status-$slot"

  if [ -n "$worktree" ]; then
    git worktree remove "$worktree" --force >> "$VERBOSE_LOG" 2>&1 || true
  fi
  if [ -n "$branch" ]; then
    git branch -D "$branch" >> "$VERBOSE_LOG" 2>&1 || true
  fi
  rm -f "$status_file"

  P_PIDS[$slot]=""
  P_WORKTREES[$slot]=""
  P_BRANCHES[$slot]=""
  P_TASK_LINES[$slot]=""
  P_TASK_DESCS[$slot]=""
  P_ACTIVE[$slot]=false
  PARALLEL_LAST_ANALYSIS=0

  house_log "   🐭 Jerry #$slot's hideout demolished. Clean slate."
}

# ─── Cleanup All ─────────────────────────────────────────────────────────────

cleanup_all_parallel() {
  for ((i=0; i<MAX_PARALLEL; i++)); do
    if [ "${P_ACTIVE[$i]}" = true ]; then
      [ -n "${P_PIDS[$i]}" ] && kill_tree "${P_PIDS[$i]}"
      cleanup_parallel_slot "$i"
    fi
  done
}
