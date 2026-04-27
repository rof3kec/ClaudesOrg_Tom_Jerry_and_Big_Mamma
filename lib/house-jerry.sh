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

# ─── Fill Jerry Slots ──────────────────────────────────────────────────────

fill_jerry_slots() {
  # 🧠 SMART ROUTING: Fill free Jerry slots with conflict-aware task selection
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

  house_log "👩🏽🐭 Pending task(s) in '$ACTIVE_SECTION_NAME', $free_slots Jerry slot(s) free — smart routing engaged!"

  # Collect candidate tasks (with continuation lines)
  local -a CAND_LINES=()
  local -a CAND_DESCS=()
  while IFS= read -r candidate; do
    local line_num
    line_num=$(echo "$candidate" | cut -d: -f1)
    [ "$line_num" -lt "$ACTIVE_SECTION_START" ] && continue
    [ "$line_num" -gt "$ACTIVE_SECTION_END" ] && break

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

  if [ ${#CAND_LINES[@]} -eq 0 ]; then
    local section_pending
    section_pending=$(sed -n "${ACTIVE_SECTION_START},${ACTIVE_SECTION_END}p" "$TASK_FILE" 2>/dev/null | grep -c '^\[ \] ' || true)
    if [ "${section_pending:-0}" -gt 0 ]; then
      house_log "   🐭 $section_pending [ ] task(s) in section but all already claimed"
    else
      house_log "   🐭 No [ ] tasks in active section"
    fi
    PARALLEL_LAST_ANALYSIS=$now_ts
    return 1
  fi

  # 🧠 CONFLICT-AWARE ASSIGNMENT: Only assign tasks that don't conflict with already-running Jerrys
  local -a assigned_lines=()
  local spawned=0

  for ((si=0; si<MAX_PARALLEL; si++)); do
    [ "${P_ACTIVE[$si]}" = true ] && continue
    [ "$spawned" -ge "$free_slots" ] && break

    # Find next task that doesn't conflict with already-assigned tasks
    local assigned=false
    for ((ti=0; ti<${#CAND_LINES[@]}; ti++)); do
      local cand_line="${CAND_LINES[$ti]}"
      local cand_desc="${CAND_DESCS[$ti]}"

      # Skip if already assigned this loop
      local already_assigned=false
      for assigned_line in "${assigned_lines[@]}"; do
        [ "$assigned_line" = "$cand_line" ] && already_assigned=true && break
      done
      [ "$already_assigned" = true ] && continue

      # Check conflict with other running Jerrys
      local has_conflict=false
      for ((oi=0; oi<MAX_PARALLEL; oi++)); do
        [ "$oi" = "$si" ] && continue
        [ "${P_ACTIVE[$oi]}" = true ] || continue

        local other_line="${P_TASK_LINES[$oi]}"
        if ! can_parallelize_with "$cand_line" "$other_line" 2>/dev/null; then
          has_conflict=true
          break
        fi
      done

      # Also check conflict with tasks we're about to assign in this batch
      for assigned_line in "${assigned_lines[@]}"; do
        if ! can_parallelize_with "$cand_line" "$assigned_line" 2>/dev/null; then
          has_conflict=true
          break
        fi
      done

      if [ "$has_conflict" = false ]; then
        # Found a safe task — assign it
        spawn_parallel_worker "$si" "$cand_line" "$cand_desc"
        if [ "${P_ACTIVE[$si]}" = true ]; then
          assigned_lines+=("$cand_line")
          spawned=$((spawned + 1))
          assigned=true
        fi
        break
      fi
    done

    [ "$assigned" = false ] && house_log "   🐭⚠ Jerry #$si: no conflict-free tasks available"
  done

  PARALLEL_LAST_ANALYSIS=$now_ts

  if [ "$spawned" -gt 0 ]; then
    house_log "👩🏽🐭 Deployed $spawned Jerry(s) with zero-conflict routing! \"Smart work beats hard work!\""
  elif [ "$free_slots" -gt 0 ] && [ ${#CAND_LINES[@]} -gt 0 ]; then
    house_log "   🐭 All remaining tasks conflict with running Jerrys — Tom will handle them sequentially"
  fi
  return 0
}

# ─── Spawn a Jerry ──────────────────────────────────────────────────────────

spawn_parallel_worker() {
  local slot="$1"
  local task_line="$2"
  local task_desc="$3"
  local status_file=".parallel-status-$slot"
  local log_file="claude-parallel-$slot.log"

  house_log "${_C_BLUE}▶ TASK STARTED ─── [Jerry #${slot}] #${task_line}: ${task_desc}${_C_RST}"

  # Mark task as in-progress (with race-condition guard)
  lock_tasks
  # Pre-check: verify task is still [ ] before claiming (prevents double-claim with Tom)
  local current
  current=$(sed -n "${task_line}p" "$TASK_FILE" 2>/dev/null)
  if ! echo "$current" | grep -q '^\[ \] '; then
    unlock_tasks
    house_log "🐭⚠ Jerry #$slot: task at line $task_line already claimed. Skipping."
    return
  fi
  sedi "${task_line}s/^\[ \] /[!] /" "$TASK_FILE"
  unlock_tasks

  # Write Jerry's status
  local safe_desc="${task_desc//$'\n'/ }"
  cat > "$status_file" <<EOF
STATE=running
SLOT=$slot
TASK_LINE=$task_line
TASK_DESC=$safe_desc
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

  # Spawn Claude in same directory as Tom — Jerry just edits files, Big Mamma handles git
  ($CLAUDE_SPAWN "$task_desc
${JERRY_CONTEXT}
(IMPORTANT: Edit files only — do NOT run build, test, or install commands. Do NOT use git commands. Big Mamma will handle commits and merges.)" >> "$log_file" 2>&1; touch "$NOTIFICATION_FILE"; kill -USR1 $$ 2>/dev/null) &

  P_PIDS[$slot]=$!
  P_TASK_LINES[$slot]="$task_line"
  P_TASK_DESCS[$slot]="$task_desc"
  P_ACTIVE[$slot]=true

  house_log "   🐭 Jerry #$slot scurrying away (PID ${P_PIDS[$slot]})"
}

# ─── Check Jerry Workers ────────────────────────────────────────────────────

check_parallel_workers() {
  for ((i=0; i<MAX_PARALLEL; i++)); do
    [ "${P_ACTIVE[$i]}" = true ] || continue

    if is_process_alive "${P_PIDS[$i]}"; then
      # Still running — periodic status + hard timeout check
      local status_file=".parallel-status-$i"
      if [ -f "$status_file" ]; then
        sedi "s/^UPDATED=.*/UPDATED=$(date +%s)/" "$status_file" 2>/dev/null
        local p_started
        p_started=$(grep '^STARTED=' "$status_file" 2>/dev/null | cut -d= -f2)
        if [ -n "$p_started" ]; then
          local p_age=$(( $(date +%s) - p_started ))
          local p_age_str="${p_age}s"
          [ "$p_age" -gt 60 ] && p_age_str="$((p_age / 60))m$((p_age % 60))s"

          # Hard timeout: kill Jerry if stuck too long
          if [ "$p_age" -ge "$TASK_HARD_TIMEOUT" ]; then
            house_log "👩🏽🔨 Jerry #$i stuck for $((p_age / 60))m (limit: $((TASK_HARD_TIMEOUT / 60))m). PULLING THE PLUG!"
            kill_tree "${P_PIDS[$i]}"
            sleep 2
            record_task_failure "${P_TASK_DESCS[$i]}" > /dev/null
            lock_tasks
            local tl="${P_TASK_LINES[$i]}"
            sedi "${tl}s/^\[!\] /[-] /" "$TASK_FILE"
            unlock_tasks
            house_log "   👩🏽 Task #${tl} marked FAILED. \"$((TASK_HARD_TIMEOUT / 60)) minutes is $((TASK_HARD_TIMEOUT / 60)) minutes, Jerry!\""
            LAST_FAILURE_TIME=$(date +%s)
            cleanup_parallel_slot "$i"
            continue
          fi

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
      # Mark task as ready for QA (Spike will promote to [x])
      lock_tasks
      local tl="${P_TASK_LINES[$i]}"
      sedi "${tl}s/^\[!\] /[q] /" "$TASK_FILE"
      unlock_tasks
      PENDING_COMMIT=true
      LAST_CHANGE_TIME=$(date +%s)
      cleanup_parallel_slot "$i"
    else
      house_log "${_C_RED}✗ TASK FAILED ─── [Jerry #${i}] #${P_TASK_LINES[$i]} (exit $p_exit): ${P_TASK_DESCS[$i]}${_C_RST}"
      local fail_count
      fail_count=$(record_task_failure "${P_TASK_DESCS[$i]}")
      lock_tasks
      local tl="${P_TASK_LINES[$i]}"
      if [ "$fail_count" -ge "$TASK_FAIL_MAX" ]; then
        sedi "${tl}s/^\[!\] /[-] /" "$TASK_FILE"
        house_log "   👩🏽✗ Task failed $fail_count times across workers. Marking PERMANENTLY failed."
      else
        sedi "${tl}s/^\[!\] /[ ] /" "$TASK_FILE"
        house_log "   🐭 Re-queued (failure $fail_count/$TASK_FAIL_MAX)"
      fi
      unlock_tasks
      LAST_FAILURE_TIME=$(date +%s)
      cleanup_parallel_slot "$i"
    fi
  done
}

# ─── Cleanup Slot ────────────────────────────────────────────────────────────

cleanup_parallel_slot() {
  local slot="$1"
  local status_file=".parallel-status-$slot"

  rm -f "$status_file"

  P_PIDS[$slot]=""
  P_TASK_LINES[$slot]=""
  P_TASK_DESCS[$slot]=""
  P_ACTIVE[$slot]=false
  PARALLEL_LAST_ANALYSIS=0

  house_log "   🐭 Jerry #$slot finished. Clean slate."
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
