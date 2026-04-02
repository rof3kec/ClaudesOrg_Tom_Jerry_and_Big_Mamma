#!/usr/bin/env bash
# claude-supervisor.sh — 👩🏽 Big Mamma: she runs this house and EVERYBODY knows it
#
# "I don't ask twice. I don't ASK once. I TELL."
#                                        — Big Mamma
#
# Usage:
#   ./claude-supervisor.sh                                    # auto-detect branch
#   ./claude-supervisor.sh my-feature-branch                  # explicit branch
#   ./claude-supervisor.sh my-dev TASKS.md                   # branch + task file
#   ./claude-supervisor.sh my-dev TASKS.md --main            # merge to main when done
#   ./claude-supervisor.sh my-dev TASKS.md --main --auto     # auto mode for parallel
#
# Architecture:
#   Big Mamma (the boss) coordinates:
#     - 🐱 Tom (claude-worker.sh) — primary task chaser
#     - 🐭 2x Jerry (spawned in git worktrees) — parallel sneaky workers
#     - 🐶 Spike (claude-qa.sh) — quality enforcer
#   Big Mamma handles: commits, pushes, merges, hibernation, stale recovery.

set -u

BRANCH="${1:-}"
TASK_FILE="${2:-TASKS.md}"
MERGE_MAIN="${3:-}"
AUTO_MODE="${4:-}"
LOG_FILE="claude-supervisor.log"
POLL_INTERVAL=15
LAST_DONE_COUNT=0
COMMIT_BATCH_WAIT=30       # debounce: wait this long after last change before committing
HIBERNATE_FILE=".worker-hibernate"
WORKER_HIBERNATING=false
LOCK_DIR=".tasks.lock"
WORKER_PID_FILE=".claude-worker.pid"
GRACE_CYCLES=0             # cycles with no live worker while [!] tasks exist
GRACE_THRESHOLD=16         # 16 x 15s = 4min grace before declaring stale
ALIVE_TICKS=0              # activity logging cadence (reset when worker dies)
STATUS_FILE=".worker-status"
MAX_TASK_AGE=600           # 10 min — warn if task exceeds this
PUSH_PENDING=false
MERGED_TO_MAIN=false

# Spike (QA) integration
QA_STATUS_FILE=".qa-status"
QA_STATE=""

# Jerry (parallel workers) — 2 slots (indexed 0 and 1)
MAX_PARALLEL=2
P_PIDS=("" "")
P_WORKTREES=("" "")
P_BRANCHES=("" "")
P_TASK_LINES=("" "")
P_TASK_DESCS=("" "")
P_ACTIVE=(false false)
PARALLEL_LAST_ANALYSIS=0

# ─── Helpers ───────────────────────────────────────────────────────────────────

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [BIG MAMMA] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

die() {
  log "FATAL: $*"
  exit 1
}

short() {
  local w
  w=$(echo "$1" | wc -w | tr -d ' ')
  if [ "$w" -gt 10 ]; then
    echo "$1" | cut -d' ' -f1-10 | sed 's/$/ (...)/'
  else
    echo "$1"
  fi
}

# Verbose log for git command output (keeps main log clean)
VERBOSE_LOG="claude-supervisor-verbose.log"

# ─── File locking (mkdir is atomic on all platforms) ─────────────────────────

lock_tasks() {
  local attempts=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 0.5
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 20 ]; then
      log "WARNING: Task lock timeout after 10s, forcing unlock"
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" 2>/dev/null || true
      return
    fi
  done
}

unlock_tasks() {
  rm -rf "$LOCK_DIR"
}

# ─── Task counters ────────────────────────────────────────────────────────────

count_done() {
  local n
  n=$(grep -c '^\[x\] ' "$TASK_FILE" 2>/dev/null) || true
  echo "${n:-0}"
}

count_in_progress() {
  local n
  n=$(grep -c '^\[!\] ' "$TASK_FILE" 2>/dev/null) || true
  echo "${n:-0}"
}

count_pending() {
  local n
  n=$(grep -c '^\[ \] ' "$TASK_FILE" 2>/dev/null) || true
  echo "${n:-0}"
}

count_failed() {
  local n
  n=$(grep -c '^\[-\] ' "$TASK_FILE" 2>/dev/null) || true
  echo "${n:-0}"
}

has_changes() {
  ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]
}

get_recent_done_tasks() {
  local count="${1:-1}"
  grep '^\[x\] ' "$TASK_FILE" | tail -"$count" | sed 's/^\[x\] //' | head -c 500
}

# ─── Process liveness (cross-platform) ───────────────────────────────────────

is_process_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null && return 0
  ps -p "$pid" > /dev/null 2>&1 && return 0
  return 1
}

is_claude_alive() {
  if [ -f "$WORKER_PID_FILE" ]; then
    local pid
    pid=$(cat "$WORKER_PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && is_process_alive "$pid"; then
      return 0
    fi
  fi
  return 1
}

# ─── Jerry (parallel worker) helpers ────────────────────────────────────────

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

# ─── Tom's status ───────────────────────────────────────────────────────────

read_worker_status() {
  WSTAT_STATE="" WSTAT_WORKER_PID="" WSTAT_CLAUDE_PID=""
  WSTAT_TASK_LINE="" WSTAT_TASK_DESC="" WSTAT_TASK_STARTED="" WSTAT_UPDATED=""
  [ -f "$STATUS_FILE" ] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      STATE) WSTAT_STATE="$value" ;;
      WORKER_PID) WSTAT_WORKER_PID="$value" ;;
      CLAUDE_PID) WSTAT_CLAUDE_PID="$value" ;;
      TASK_LINE) WSTAT_TASK_LINE="$value" ;;
      TASK_DESC) WSTAT_TASK_DESC="$value" ;;
      TASK_STARTED) WSTAT_TASK_STARTED="$value" ;;
      UPDATED) WSTAT_UPDATED="$value" ;;
    esac
  done < "$STATUS_FILE"
  return 0
}

# ─── Spike's status ───────────────────────────────────────────────────────────

read_qa_status() {
  # Sets QA_STATE and QA_VALIDATED_DONE globals. Returns 0 if file exists.
  QA_STATE="idle"
  QA_VALIDATED_DONE=""
  [ -f "$QA_STATUS_FILE" ] || return 1
  QA_STATE=$(grep '^STATE=' "$QA_STATUS_FILE" 2>/dev/null | cut -d= -f2)
  QA_VALIDATED_DONE=$(grep '^VALIDATED_DONE=' "$QA_STATUS_FILE" 2>/dev/null | cut -d= -f2)
  [ -n "$QA_STATE" ] || QA_STATE="idle"
  return 0
}

# ─── Stale Task Recovery ────────────────────────────────────────────────────

recover_stale_tasks() {
  lock_tasks
  local stale_count
  stale_count=$(count_in_progress)
  if [ "$stale_count" -eq 0 ]; then
    unlock_tasks
    return 1
  fi

  # Collect active Jerry task lines to exclude from recovery
  local exclude_lines=""
  local exclude_count=0
  for ((i=0; i<MAX_PARALLEL; i++)); do
    if [ "${P_ACTIVE[$i]}" = true ] && [ -n "${P_TASK_LINES[$i]}" ]; then
      local ptask
      ptask=$(sed -n "${P_TASK_LINES[$i]}p" "$TASK_FILE" 2>/dev/null)
      if echo "$ptask" | grep -q '^\[!\] '; then
        exclude_lines="${exclude_lines:+$exclude_lines,}${P_TASK_LINES[$i]}"
        exclude_count=$((exclude_count + 1))
        stale_count=$((stale_count - 1))
      fi
    fi
  done

  if [ "$stale_count" -eq 0 ]; then
    unlock_tasks
    return 1
  fi

  if [ -n "$exclude_lines" ]; then
    # Build awk exclusion — skip Jerry's tasks
    local awk_cond=""
    IFS=',' read -ra EXCL <<< "$exclude_lines"
    for el in "${EXCL[@]}"; do
      awk_cond="${awk_cond:+$awk_cond || }NR==$el"
    done
    awk "($awk_cond){print; next} /^\\[!\\] /{sub(/^\\[!\\] /,\"[ ] \")} {print}" \
      "$TASK_FILE" > "$TASK_FILE.tmp" && mv "$TASK_FILE.tmp" "$TASK_FILE"
    unlock_tasks
    log "👩🏽😤 THOMAS! $stale_count task(s) stuck at [!]! Resetting them. (Kept $exclude_count Jerry task(s))"
    return 0
  fi

  log "👩🏽😤 THOMAS!! You fell ASLEEP with $stale_count task(s) in your MOUTH!"
  log "   Lord have mercy... resetting them to [ ] so you can TRY AGAIN."
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' 's/^\[!\] /[ ] /' "$TASK_FILE"
  else
    sed -i 's/^\[!\] /[ ] /' "$TASK_FILE"
  fi
  unlock_tasks
  log "   Mm-hmm. Tom will pick them up on next cycle. He BETTER."
  return 0
}

# ─── Cleanup completed tasks ────────────────────────────────────────────────

cleanup_done_tasks() {
  # Only safe when nobody's holding line-number references
  if [ "$IN_PROGRESS" -gt 0 ] || any_parallel_active; then
    return
  fi

  # Only remove tasks Spike has validated (fence)
  local max_remove="${QA_VALIDATED_DONE:-0}"
  [ "$max_remove" -gt 0 ] || return

  lock_tasks
  local done_count
  done_count=$(grep -c '^\[x\] ' "$TASK_FILE" 2>/dev/null) || true
  done_count="${done_count:-0}"

  if [ "$done_count" -eq 0 ]; then
    unlock_tasks
    return
  fi

  # Cap at what Spike validated — unvalidated [x] tasks stay
  local to_remove=$done_count
  [ "$to_remove" -gt "$max_remove" ] && to_remove=$max_remove

  log "👩🏽🧹 Big Mamma's tidying the task list: $to_remove/$done_count done task(s) (Spike validated: $max_remove)"

  # Remove first N [x] lines (top-to-bottom order matches execution order)
  awk -v n="$to_remove" '/^\[x\] / && removed < n { removed++; next } { print }' \
    "$TASK_FILE" > "$TASK_FILE.tmp" && mv "$TASK_FILE.tmp" "$TASK_FILE"

  # Collapse 3+ consecutive blank lines -> 2
  awk 'NF{c=0;print;next} {c++} c<=2{print}' "$TASK_FILE" > "$TASK_FILE.tmp" && mv "$TASK_FILE.tmp" "$TASK_FILE"

  unlock_tasks

  # Commit and push the cleanup
  git add "$TASK_FILE" 2>/dev/null
  git commit -m "auto: cleaned $to_remove completed tasks from $TASK_FILE" >> "$VERBOSE_LOG" 2>&1 || true
  push_changes || true

  # Reset counter since lines are gone
  LAST_DONE_COUNT=$(count_done)

  log "   👩🏽✓ House is tidy. That's how we DO things around here."
}

# ─── Hibernation Control ────────────────────────────────────────────────────

hibernate_worker() {
  if [ "$WORKER_HIBERNATING" = false ]; then
    echo "HIBERNATE" > "$HIBERNATE_FILE"
    WORKER_HIBERNATING=true
    log "👩🏽 Alright Tom, you can rest now... but I got my EYE on you. 🐱💤"
  fi
}

wake_worker() {
  if [ "$WORKER_HIBERNATING" = true ]; then
    rm -f "$HIBERNATE_FILE"
    WORKER_HIBERNATING=false
    log "👩🏽📢 TOM! Get UP! There's work to do, you LAZY cat! 🐱⏰"
  fi
}

# ─── Push with fallback strategies ──────────────────────────────────────────

push_changes() {
  log "👩🏽📤 Big Mamma: Sending this out the door to origin/$BRANCH..."

  if git push origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
    log "👩🏽✓ Out the DOOR! Pushed to origin/$BRANCH"
    return 0
  fi

  log "👩🏽⚠ Door's stuck! Trying the back door... (pull --rebase)"
  if git pull --rebase origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
    if git push origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
      log "👩🏽✓ Got it out the back door! Pushed after rebase."
      return 0
    fi
  fi
  git rebase --abort >> "$VERBOSE_LOG" 2>&1 || true

  log "👩🏽⚠ Back door's stuck too! Trying the WINDOW... (merge)"
  if git pull --no-rebase origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
    if git push origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
      log "👩🏽✓ Shoved it through the window! Pushed after merge."
      return 0
    fi
  fi

  log "👩🏽⚠ Lord have MERCY... getting the BATTERING RAM (force-with-lease)"
  if git push --force-with-lease origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
    log "👩🏽✓ BOOM! Door's DOWN! Force-pushed (with lease) to origin/$BRANCH"
    return 0
  fi

  log "👩🏽✗ Can't get this out the door no-HOW. Will try again next cycle."
  PUSH_PENDING=true
  return 1
}

# ─── Merge to main ──────────────────────────────────────────────────────────

merge_to_main() {
  log "👩🏽🚀 ALL tasks done! Big Mamma's moving this to the MAIN STAGE!"
  log "   Merging $BRANCH into main..."

  if ! git push origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
    log "👩🏽⚠ Couldn't push $BRANCH before merge. Trying anyway..."
  fi

  if ! git fetch origin main >> "$VERBOSE_LOG" 2>&1; then
    log "👩🏽✗ Couldn't fetch main. Merge CANCELLED. I am NOT happy."
    return 1
  fi

  if ! git checkout main >> "$VERBOSE_LOG" 2>&1; then
    log "👩🏽✗ Couldn't checkout main. Merge CANCELLED."
    git checkout "$BRANCH" >> "$VERBOSE_LOG" 2>&1 || true
    return 1
  fi

  git pull origin main >> "$VERBOSE_LOG" 2>&1 || true

  if git merge "$BRANCH" -m "merge: $BRANCH into main (all tasks completed)" >> "$VERBOSE_LOG" 2>&1; then
    log "👩🏽✓ Merged $BRANCH into main! *chef's kiss*"
    if git push origin main >> "$VERBOSE_LOG" 2>&1; then
      log "👩🏽✓ Main is LIVE! Pushed to origin. Big Mamma is PROUD!"
      MERGED_TO_MAIN=true
    else
      log "👩🏽✗ Merged locally but couldn't push main. Push it yourself, child."
    fi
  else
    log "👩🏽✗ MERGE CONFLICT! Lord have mercy!"
    log "   \"I swear, y'all can't do NOTHING right without me!\""
    git merge --abort >> "$VERBOSE_LOG" 2>&1 || true
  fi

  git checkout "$BRANCH" >> "$VERBOSE_LOG" 2>&1 || true
}

# ─── Jerry (Parallel Worker) Management — 2 slots ──────────────────────────

analyze_for_parallelism() {
  # Count free Jerry slots
  local free_slots=0
  for ((i=0; i<MAX_PARALLEL; i++)); do
    [ "${P_ACTIVE[$i]}" = false ] && free_slots=$((free_slots + 1))
  done
  [ "$free_slots" -eq 0 ] && return 1
  [ "$PENDING" -lt 2 ] && return 1
  [ "$IN_PROGRESS" -eq 0 ] && return 1
  [ "$PENDING" -eq "$PARALLEL_LAST_ANALYSIS" ] && return 1

  PARALLEL_LAST_ANALYSIS=$PENDING

  log "👩🏽🔍 Hmm... $PENDING pending tasks and $free_slots Jerry slot(s) free. Let me think..."

  # Get pending tasks with line numbers
  PENDING_TASKS=$(grep -n '^\[ \] ' "$TASK_FILE" | head -10)

  # Gather ALL currently in-progress tasks for context
  IN_PROGRESS_TASKS=""
  if read_worker_status && [ -n "$WSTAT_TASK_DESC" ]; then
    IN_PROGRESS_TASKS="Primary worker: $WSTAT_TASK_DESC"
  fi
  for ((i=0; i<MAX_PARALLEL; i++)); do
    if [ "${P_ACTIVE[$i]}" = true ]; then
      IN_PROGRESS_TASKS="${IN_PROGRESS_TASKS:+$IN_PROGRESS_TASKS
}Parallel worker #$i: ${P_TASK_DESCS[$i]}"
    fi
  done

  # Ask Claude to identify independent tasks
  CLAUDE_ANALYZE="claude -p"
  [ "$AUTO_MODE" = "--auto" ] && CLAUDE_ANALYZE="$CLAUDE_ANALYZE --dangerously-skip-permissions"

  ANALYSIS=$($CLAUDE_ANALYZE "You are analyzing tasks for a software project.

Identify up to $free_slots task(s) that can safely run in PARALLEL with the current work. Each must:
- Touch DIFFERENT files/features than any in-progress task
- Touch DIFFERENT files/features than each other
- Have NO dependency on other pending tasks
- Be self-contained

Currently in progress:
$IN_PROGRESS_TASKS

Pending tasks:
$PENDING_TASKS

Reply with comma-separated line numbers, e.g.: PARALLEL:18,25
If only one is safe: PARALLEL:18
If none are safe: NONE" 2>/dev/null) || true

  if echo "$ANALYSIS" | grep -q "PARALLEL:"; then
    P_LINES=$(echo "$ANALYSIS" | grep "PARALLEL:" | head -1 | sed 's/.*PARALLEL://' | tr -d ' \r\n')

    # Parse comma-separated line numbers
    IFS=',' read -ra LINE_NUMS <<< "$P_LINES"

    local spawned=0
    for line_num in "${LINE_NUMS[@]}"; do
      line_num=$(echo "$line_num" | tr -d ' ')
      [ -z "$line_num" ] && continue

      # Find a free slot
      local slot
      slot=$(find_free_slot) || break

      # Validate it's a pending task
      TASK_AT_LINE=$(sed -n "${line_num}p" "$TASK_FILE" 2>/dev/null)
      if echo "$TASK_AT_LINE" | grep -q '^\[ \] '; then
        P_DESC=$(echo "$TASK_AT_LINE" | sed 's/^\[ \] //')
        spawn_parallel_worker "$slot" "$line_num" "$P_DESC"
        spawned=$((spawned + 1))
      else
        log "👩🏽⚠ Line $line_num ain't a pending task. Skipping that nonsense."
      fi
    done

    [ "$spawned" -gt 0 ] && return 0
  else
    log "   👩🏽 No independent tasks found — everybody stays in LINE. Sequential it is."
  fi

  return 1
}

spawn_parallel_worker() {
  local slot="$1"
  local task_line="$2"
  local task_desc="$3"
  local branch_name="parallel-${slot}-$(date +%s)"
  local worktree_dir=".worktrees/$branch_name"
  local status_file=".parallel-status-$slot"
  local log_file="claude-parallel-$slot.log"

  log "🐭🚀 Jerry #$slot, get in there! Task #${task_line}: $(short "$task_desc")"
  log "   \"Sneaky sneaky...\" — Jerry"

  # Mark task as in-progress
  lock_tasks
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "${task_line}s/^\[ \] /[!] /" "$TASK_FILE"
  else
    sed -i "${task_line}s/^\[ \] /[!] /" "$TASK_FILE"
  fi
  unlock_tasks

  # Create worktree (Jerry's hideout)
  mkdir -p .worktrees
  if ! git worktree add "$worktree_dir" -b "$branch_name" >> "$VERBOSE_LOG" 2>&1; then
    log "🐭💥 Jerry #$slot couldn't dig his tunnel (worktree failed). Reverting task."
    lock_tasks
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "${task_line}s/^\[!\] /[ ] /" "$TASK_FILE"
    else
      sed -i "${task_line}s/^\[!\] /[ ] /" "$TASK_FILE"
    fi
    unlock_tasks
    return
  fi

  # Write Jerry's status
  cat > "$status_file" <<EOF
STATE=running
SLOT=$slot
TASK_LINE=$task_line
TASK_DESC=$task_desc
BRANCH=$branch_name
WORKTREE=$worktree_dir
STARTED=$(date +%s)
EOF

  # Build command
  CLAUDE_SPAWN="claude -p"
  [ "$AUTO_MODE" = "--auto" ] && CLAUDE_SPAWN="$CLAUDE_SPAWN --dangerously-skip-permissions"

  # Spawn Claude in Jerry's hideout (worktree)
  (cd "$worktree_dir" && $CLAUDE_SPAWN "$task_desc

(IMPORTANT: You are running in an isolated git worktree. Edit files only — do NOT run build, test, or install commands like pnpm install, tsc, etc. A QA worker will verify your changes after merge.)" >> "../../$log_file" 2>&1) &

  P_PIDS[$slot]=$!
  P_TASK_LINES[$slot]="$task_line"
  P_TASK_DESCS[$slot]="$task_desc"
  P_WORKTREES[$slot]="$worktree_dir"
  P_BRANCHES[$slot]="$branch_name"
  P_ACTIVE[$slot]=true

  log "   🐭 Jerry #$slot scurrying away (PID ${P_PIDS[$slot]}) in $worktree_dir"
}

check_parallel_workers() {
  for ((i=0; i<MAX_PARALLEL; i++)); do
    [ "${P_ACTIVE[$i]}" = true ] || continue

    if is_process_alive "${P_PIDS[$i]}"; then
      # Still running — periodic status
      local status_file=".parallel-status-$i"
      if [ -f "$status_file" ]; then
        local p_started
        p_started=$(grep '^STARTED=' "$status_file" 2>/dev/null | cut -d= -f2)
        if [ -n "$p_started" ]; then
          local p_age=$(( $(date +%s) - p_started ))
          local p_age_str="${p_age}s"
          [ "$p_age" -gt 60 ] && p_age_str="$((p_age / 60))m$((p_age % 60))s"
          if [ $((ALIVE_TICKS % 4)) -eq 0 ] && [ "$ALIVE_TICKS" -gt 0 ]; then
            log "🐭 Jerry #$i still scurrying (${p_age_str}): $(short "${P_TASK_DESCS[$i]}")"
          fi
        fi
      fi
      continue
    fi

    # Jerry finished his mission
    wait "${P_PIDS[$i]}" 2>/dev/null
    local p_exit=$?

    if [ "$p_exit" -eq 0 ]; then
      log "🐭✓ Jerry #$i pulled it off! Task #${P_TASK_LINES[$i]} complete!"
      log "   *tiny mouse victory dance*"
      merge_parallel_worker "$i"
    else
      log "🐭💥 Jerry #$i got caught in a mousetrap! (exit $p_exit). Re-queuing for Tom."
      lock_tasks
      local tl="${P_TASK_LINES[$i]}"
      if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "${tl}s/^\[!\] /[ ] /" "$TASK_FILE"
      else
        sed -i "${tl}s/^\[!\] /[ ] /" "$TASK_FILE"
      fi
      unlock_tasks
      cleanup_parallel_slot "$i"
    fi
  done
}

merge_parallel_worker() {
  local slot="$1"
  local branch="${P_BRANCHES[$slot]}"
  local task_line="${P_TASK_LINES[$slot]}"

  log "🐭🔀 Bringing Jerry #$slot's work home (merging branch $branch)..."

  # Commit any uncommitted changes from Tom first
  if has_changes; then
    log "   Committing Tom's work-in-progress before merge..."
    git add -A 2>/dev/null
    git commit -m "auto: work in progress (pre-parallel-merge)" >> "$VERBOSE_LOG" 2>&1 || true
  fi

  if git merge "$branch" --no-edit >> "$VERBOSE_LOG" 2>&1; then
    log "🐭✓ Jerry #$slot's work merged clean! That mouse is GOOD."

    # Mark task as done
    lock_tasks
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "${task_line}s/^\[!\] /[x] /" "$TASK_FILE"
    else
      sed -i "${task_line}s/^\[!\] /[x] /" "$TASK_FILE"
    fi
    unlock_tasks

    PENDING_COMMIT=true
    LAST_CHANGE_TIME=$(date +%s)
  else
    log "🐭⚠ Jerry #$slot's work COLLIDED with Tom's! Merge conflict!"
    log "   \"Same old story...\" Re-queuing for Tom to handle sequentially."
    git merge --abort >> "$VERBOSE_LOG" 2>&1 || true

    lock_tasks
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "${task_line}s/^\[!\] /[ ] /" "$TASK_FILE"
    else
      sed -i "${task_line}s/^\[!\] /[ ] /" "$TASK_FILE"
    fi
    unlock_tasks
  fi

  cleanup_parallel_slot "$slot"
}

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

  log "   🐭 Jerry #$slot's hideout demolished. Clean slate."
}

cleanup_all_parallel() {
  for ((i=0; i<MAX_PARALLEL; i++)); do
    if [ "${P_ACTIVE[$i]}" = true ]; then
      [ -n "${P_PIDS[$i]}" ] && kill "${P_PIDS[$i]}" 2>/dev/null
      cleanup_parallel_slot "$i"
    fi
  done
}

# ─── Pre-flight checks ──────────────────────────────────────────────────────

if ! command -v git &>/dev/null; then
  die "git not found in PATH"
fi

if [ ! -d .git ]; then
  die "Not a git repository. Run from repo root."
fi

if [ ! -f "$TASK_FILE" ]; then
  die "Task file '$TASK_FILE' not found."
fi

# Detect branch
if [ -z "$BRANCH" ]; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  if [ -z "$BRANCH" ]; then
    die "Could not detect current branch. Pass it as argument."
  fi
fi

if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
  die "I will NOT push to '$BRANCH'! Use a dev branch, child. Big Mamma didn't raise no fool."
fi

if ! git remote get-url origin &>/dev/null; then
  die "No 'origin' remote configured."
fi

# ─── State ───────────────────────────────────────────────────────────────────

LAST_DONE_COUNT=$(count_done)
LAST_CHANGE_TIME=0
PENDING_COMMIT=false

# Cleanup on exit
cleanup_supervisor() {
  cleanup_all_parallel
  rm -f "$HIBERNATE_FILE"
  rm -rf "$LOCK_DIR"
  log "👩🏽 Big Mamma has left the building. Y'all are on your OWN now."
}
trap cleanup_supervisor EXIT INT TERM

# Start fresh
rm -f "$HIBERNATE_FILE"
rm -rf "$LOCK_DIR"

log "╔═══════════════════════════════════════════════════════╗"
log "║  👩🏽 Big Mamma's in the HOUSE! Everybody BEHAVE!       ║"
log "╚═══════════════════════════════════════════════════════╝"
log "Branch: $BRANCH"
log "Task file: $TASK_FILE"
log "Auto mode: ${AUTO_MODE:-off}"
log "Jerry slots: $MAX_PARALLEL"
log "Poll interval: ${POLL_INTERVAL}s"
log "Commit debounce: ${COMMIT_BATCH_WAIT}s"
log "Roll call: $(count_done) done, $(count_in_progress) in-progress, $(count_pending) pending, $(count_failed) failed"
log "\"Now let's get this house in ORDER.\""

# ─── Main loop ───────────────────────────────────────────────────────────────

while true; do
  CURRENT_DONE=$(count_done)
  IN_PROGRESS=$(count_in_progress)
  PENDING=$(count_pending)
  FAILED=$(count_failed)
  NOW=$(date +%s)

  # Detect newly completed tasks
  if [ "$CURRENT_DONE" -gt "$LAST_DONE_COUNT" ]; then
    NEW_COMPLETIONS=$((CURRENT_DONE - LAST_DONE_COUNT))
    log "👩🏽😊 Well well! $NEW_COMPLETIONS task(s) DONE! (total: $CURRENT_DONE). That's what I like to see!"
    LAST_DONE_COUNT=$CURRENT_DONE
    LAST_CHANGE_TIME=$NOW
    PENDING_COMMIT=true
  fi

  # ── Retry pending pushes ──
  if [ "$PUSH_PENDING" = true ] && [ "$IN_PROGRESS" -eq 0 ]; then
    log "👩🏽🔁 Let me try that door again..."
    if push_changes; then
      PUSH_PENDING=false
    fi
  fi

  # ── Wake Tom if tasks exist ──
  if [ "$PENDING" -gt 0 ] || [ "$IN_PROGRESS" -gt 0 ]; then
    wake_worker
  fi

  # ── Check on the Jerrys ──
  check_parallel_workers

  # ── Stale task detection (status-aware) ──
  if [ "$IN_PROGRESS" -gt 0 ]; then
    WORKER_ALIVE=false
    CLAUDE_PROC_ALIVE=false
    TASK_AGE=0

    # Primary: read Tom's status file
    if read_worker_status; then
      [ -n "$WSTAT_WORKER_PID" ] && is_process_alive "$WSTAT_WORKER_PID" && WORKER_ALIVE=true
      [ -n "$WSTAT_CLAUDE_PID" ] && is_process_alive "$WSTAT_CLAUDE_PID" && CLAUDE_PROC_ALIVE=true
      if [ -n "$WSTAT_TASK_STARTED" ] && [ "$WSTAT_TASK_STARTED" -gt 0 ] 2>/dev/null; then
        TASK_AGE=$(( $(date +%s) - WSTAT_TASK_STARTED ))
      fi
    fi

    # Fallback: check PID file directly
    if [ "$CLAUDE_PROC_ALIVE" = false ] && is_claude_alive; then
      CLAUDE_PROC_ALIVE=true
    fi

    # Count any active Jerry as alive too
    for ((pi=0; pi<MAX_PARALLEL; pi++)); do
      if [ "${P_ACTIVE[$pi]}" = true ] && is_process_alive "${P_PIDS[$pi]}" 2>/dev/null; then
        WORKER_ALIVE=true
        break
      fi
    done

    if [ "$WORKER_ALIVE" = true ] || [ "$CLAUDE_PROC_ALIVE" = true ]; then
      GRACE_CYCLES=0
      ALIVE_TICKS=$((ALIVE_TICKS + 1))

      AGE_STR="${TASK_AGE}s"
      [ "$TASK_AGE" -gt 60 ] && AGE_STR="$((TASK_AGE / 60))m$((TASK_AGE % 60))s"
      DESC_SHORT=$(short "${WSTAT_TASK_DESC:-unknown task}")

      # Log worker activity every ~60s + on first detection
      if [ "$ALIVE_TICKS" -eq 1 ] || [ $((ALIVE_TICKS % 4)) -eq 0 ]; then
        ALIVE_DETAIL=""
        active_p=$(count_active_parallel)
        [ "$WORKER_ALIVE" = true ] && ALIVE_DETAIL="🐱tom"
        [ "$CLAUDE_PROC_ALIVE" = true ] && ALIVE_DETAIL="${ALIVE_DETAIL:+$ALIVE_DETAIL+}claude"
        [ "$active_p" -gt 0 ] && ALIVE_DETAIL="${ALIVE_DETAIL}+🐭${active_p}xjerry"
        log "👩🏽👀 Big Mamma's watching ($ALIVE_DETAIL, ${AGE_STR}): $DESC_SHORT"
      fi

      if [ "$TASK_AGE" -gt "$MAX_TASK_AGE" ] && [ $((ALIVE_TICKS % 8)) -eq 0 ]; then
        log "👩🏽⏰ Tom's been at this for ${AGE_STR}! (over $((MAX_TASK_AGE / 60))m). He's alive... just SLOW."
      fi

      # ── Try deploying Jerrys while Tom is busy ──
      analyze_for_parallelism

      sleep "$POLL_INTERVAL"
      continue
    fi

    # Neither Tom nor Claude is alive
    ALIVE_TICKS=0

    if [ -f "$HIBERNATE_FILE" ]; then
      log "👩🏽😤 Tom's HIBERNATING but $IN_PROGRESS task(s) stuck at [!]?! Oh HELL no."
      recover_stale_tasks
      wake_worker
      GRACE_CYCLES=0
      sleep "$POLL_INTERVAL"
      continue
    fi

    # Dead worker — grace period before recovery
    GRACE_CYCLES=$((GRACE_CYCLES + 1))
    if [ "$GRACE_CYCLES" -eq 1 ]; then
      log "👩🏽⚠ Hmm... I don't hear Tom OR Jerry. Grace period: ${GRACE_THRESHOLD} cycles (~$((GRACE_THRESHOLD * POLL_INTERVAL))s)..."
    fi
    if [ "$GRACE_CYCLES" -ge "$GRACE_THRESHOLD" ]; then
      log "👩🏽😤 THOMAS! You been GONE for $((GRACE_CYCLES * POLL_INTERVAL))s! Recovering $IN_PROGRESS stuck task(s)..."
      log "   \"I swear, that cat is gonna give me GRAY HAIR!\""
      recover_stale_tasks
      GRACE_CYCLES=0
    fi
    sleep "$POLL_INTERVAL"
    continue
  else
    GRACE_CYCLES=0
    ALIVE_TICKS=0
  fi

  # ── Commit + Spike-gated push ──
  if [ "$PENDING_COMMIT" = true ]; then
    ELAPSED=$((NOW - LAST_CHANGE_TIME))
    if [ "$ELAPSED" -lt "$COMMIT_BATCH_WAIT" ]; then
      REMAINING=$((COMMIT_BATCH_WAIT - ELAPSED))
      log "👩🏽⏳ Hold your horses... ${REMAINING}s until commit (letting things settle)"
      sleep "$POLL_INTERVAL"
      continue
    fi

    # Commit changes locally (always — push is Spike-gated)
    if has_changes; then
      log "👩🏽📦 Packaging up the work..."
      git add -A 2>/dev/null

      DONE_SUMMARY=$(get_recent_done_tasks 5)
      COMMIT_MSG="auto: completed tasks (supervisor)

Tasks done:
$DONE_SUMMARY

Status: $CURRENT_DONE done, $PENDING pending, $FAILED failed"

      if git commit -m "$COMMIT_MSG" >> "$VERBOSE_LOG" 2>&1; then
        log "👩🏽✓ Committed locally. Mm-hmm."
      else
        log "👩🏽 Nothing to commit. Moving on."
      fi
    fi

    # Push is gated on Spike's approval
    if read_qa_status; then
      # Spike is on duty — check his verdict
      case "$QA_STATE" in
        passed|passed_with_warnings)
          if [ "$QA_STATE" = "passed_with_warnings" ]; then
            log "👩🏽⚠ Spike passed it with WARNINGS. Good enough. Pushing."
          else
            log "👩🏽😊 Spike says it's CLEAN! That's what I like to hear! Pushing..."
          fi
          push_changes
          PENDING_COMMIT=false
          cleanup_done_tasks
          ;;
        checking)
          log "👩🏽⏳ Spike's still sniffing around... hold your horses, Tom."
          ;;
        failed)
          log "👩🏽😤 Spike found a MESS! Tom, you better FIX that!"
          log "   (Spike will inject a fix task. We wait.)"
          ;;
        idle)
          log "👩🏽⏳ Waiting for Spike to start his rounds..."
          ;;
      esac
    else
      # No Spike on duty — push without QA gate
      log "👩🏽⚠ Spike's not around! Pushing without QA. Lord help us."
      push_changes
      PENDING_COMMIT=false
    fi
  fi

  # ── All tasks done? ──
  if [ "$PENDING" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ] && ! any_parallel_active; then
    hibernate_worker
    if [ "$FAILED" -gt 0 ]; then
      log "👩🏽 All tasks processed. $CURRENT_DONE done, $FAILED FAILED. Tom is resting."
      if [ "$MERGE_MAIN" = "--main" ] && [ "$MERGED_TO_MAIN" = false ]; then
        log "👩🏽✗ NOT merging to main — $FAILED task(s) failed. Fix them FIRST, Thomas."
      fi
    else
      log "👩🏽🎉 HALLELUJAH! ALL $CURRENT_DONE tasks are DONE! Big Mamma is PROUD!"
      log "   \"Now THAT'S how you run a house!\""
      if [ "$MERGE_MAIN" = "--main" ] && [ "$MERGED_TO_MAIN" = false ] && [ "$PUSH_PENDING" = false ]; then
        merge_to_main
      fi
    fi
  fi

  sleep "$POLL_INTERVAL"
done
