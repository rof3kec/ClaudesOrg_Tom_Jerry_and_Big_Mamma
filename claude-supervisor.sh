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
#   ./claude-supervisor.sh my-dev TASKS.md --main --auto 4   # 4 Jerry slots
#
# Architecture:
#   Big Mamma (the boss) coordinates:
#     - 🐱 Tom (claude-worker.sh) — primary task chaser
#     - 🐭 Nx Jerry (spawned in git worktrees) — parallel sneaky workers
#     - 🐶 Spike (claude-qa.sh) — quality enforcer
#   Big Mamma handles: commits, pushes, merges, hibernation, stale recovery.

set -u

BRANCH="${1:-}"
TASK_FILE="${2:-TASKS.md}"
MERGE_MAIN="${3:-}"
AUTO_MODE="${4:-}"
MAX_PARALLEL="${5:-2}"
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
ALL_DONE_LOGGED=false        # suppress repeated "all done" spam
IDLE_SHUTDOWN_AFTER=1800     # 30 min idle with no tasks = graceful shutdown
IDLE_SHUTDOWN_START=0        # timestamp when idle shutdown timer started
RETRY_MAX=1                  # max retries for [-] failed tasks
RETRIED_TASKS=""             # track which tasks we've already retried (by content hash)

# Spike (QA) integration
QA_STATUS_FILE=".qa-status"
QA_STATE=""
QA_CHECKING_TASKS=""

# Jerry (parallel workers) — N slots (configured via --jerries flag, eagerly filled)
P_PIDS=()
P_WORKTREES=()
P_BRANCHES=()
P_TASK_LINES=()
P_TASK_DESCS=()
P_ACTIVE=()
for ((_ji=0; _ji<MAX_PARALLEL; _ji++)); do
  P_PIDS+=("")
  P_WORKTREES+=("")
  P_BRANCHES+=("")
  P_TASK_LINES+=("")
  P_TASK_DESCS+=("")
  P_ACTIVE+=(false)
done
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

# ─── Section-aware task selection ──────────────────────────────────────────────
# Finds the first ## section (after the separator) with incomplete tasks
# ([ ], [!], or [-]). Sets ACTIVE_SECTION_START, ACTIVE_SECTION_END (line
# numbers, inclusive), and ACTIVE_SECTION_NAME.
# If no ## headings exist after the separator, the whole area is one section.
# Returns 1 if no active section found.

find_active_section() {
  local task_file="$1"
  local sep_line="${2:-0}"
  ACTIVE_SECTION_START=0
  ACTIVE_SECTION_END=0
  ACTIVE_SECTION_NAME=""

  local total_lines
  total_lines=$(wc -l < "$task_file" 2>/dev/null | tr -d ' ')
  total_lines="${total_lines:-0}"
  [ "$total_lines" -eq 0 ] && return 1

  # Collect ## heading line numbers after the separator
  local -a sec_starts=()
  local -a sec_names=()
  while IFS= read -r heading; do
    local hline hname
    hline=$(echo "$heading" | cut -d: -f1)
    if [ "$hline" -gt "$sep_line" ]; then
      hname=$(echo "$heading" | sed 's/^[0-9]*:## //')
      sec_starts+=("$hline")
      sec_names+=("$hname")
    fi
  done < <(grep -n '^## ' "$task_file" 2>/dev/null || true)

  # No sections: treat everything after separator as one flat section
  if [ ${#sec_starts[@]} -eq 0 ]; then
    ACTIVE_SECTION_START=$((sep_line + 1))
    ACTIVE_SECTION_END=$total_lines
    ACTIVE_SECTION_NAME="(all tasks)"
    if sed -n "${ACTIVE_SECTION_START},${ACTIVE_SECTION_END}p" "$task_file" 2>/dev/null | grep -qE '^\[[ !-]\] '; then
      return 0
    fi
    return 1
  fi

  # Check for ungrouped tasks between separator and first heading
  local first_sec="${sec_starts[0]}"
  if [ "$first_sec" -gt $((sep_line + 1)) ]; then
    local range_start=$((sep_line + 1))
    local range_end=$((first_sec - 1))
    if sed -n "${range_start},${range_end}p" "$task_file" 2>/dev/null | grep -qE '^\[[ !-]\] '; then
      ACTIVE_SECTION_START=$range_start
      ACTIVE_SECTION_END=$range_end
      ACTIVE_SECTION_NAME="(ungrouped)"
      return 0
    fi
  fi

  # Check each section in order — first with incomplete tasks wins
  for ((si=0; si<${#sec_starts[@]}; si++)); do
    local s_start="${sec_starts[$si]}"
    local s_end
    if [ $((si + 1)) -lt ${#sec_starts[@]} ]; then
      s_end=$(( ${sec_starts[$((si + 1))]} - 1 ))
    else
      s_end=$total_lines
    fi
    if sed -n "${s_start},${s_end}p" "$task_file" 2>/dev/null | grep -qE '^\[[ !-]\] '; then
      ACTIVE_SECTION_START=$s_start
      ACTIVE_SECTION_END=$s_end
      ACTIVE_SECTION_NAME="${sec_names[$si]}"
      return 0
    fi
  done

  return 1
}

# Verbose log for git command output (keeps main log clean)
VERBOSE_LOG="claude-supervisor-verbose.log"

# ANSI colors for task event visibility (rendered by tail -f in terminal)
_C_RST=$'\033[0m'
_C_BLUE=$'\033[1;94m'
_C_GREEN=$'\033[1;92m'
_C_RED=$'\033[1;91m'
_C_YELLOW=$'\033[1;93m'

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
# Note: These use a single grep call to count all states at once, reducing
# subprocess spawns on Windows where fork() is expensive (cygwin/MSYS2).

_update_task_counts() {
  # Read all counts in one pass to minimize fork overhead
  _COUNT_DONE=0 _COUNT_IP=0 _COUNT_PENDING=0 _COUNT_FAILED=0
  while IFS= read -r line; do
    case "$line" in
      "[x] "*) _COUNT_DONE=$((_COUNT_DONE + 1)) ;;
      "[!] "*) _COUNT_IP=$((_COUNT_IP + 1)) ;;
      "[ ] "*) _COUNT_PENDING=$((_COUNT_PENDING + 1)) ;;
      "[-] "*) _COUNT_FAILED=$((_COUNT_FAILED + 1)) ;;
    esac
  done < "$TASK_FILE" 2>/dev/null
}

count_done() {
  _update_task_counts
  echo "$_COUNT_DONE"
}

count_in_progress() {
  _update_task_counts
  echo "$_COUNT_IP"
}

count_pending() {
  _update_task_counts
  echo "$_COUNT_PENDING"
}

count_failed() {
  _update_task_counts
  echo "$_COUNT_FAILED"
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
  # Sets QA_STATE, QA_VALIDATED_DONE, and QA_CHECKING_TASKS globals. Returns 0 if file exists.
  QA_STATE="idle"
  QA_VALIDATED_DONE=""
  QA_CHECKING_TASKS=""
  [ -f "$QA_STATUS_FILE" ] || return 1
  QA_STATE=$(grep '^STATE=' "$QA_STATUS_FILE" 2>/dev/null | cut -d= -f2)
  QA_VALIDATED_DONE=$(grep '^VALIDATED_DONE=' "$QA_STATUS_FILE" 2>/dev/null | cut -d= -f2)
  QA_CHECKING_TASKS=$(grep '^CHECKING_TASKS=' "$QA_STATUS_FILE" 2>/dev/null | cut -d= -f2-)
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

  # Also exclude Tom's active task if he's alive
  if read_worker_status && [ -n "$WSTAT_TASK_LINE" ] && [ "$WSTAT_STATE" = "running" ]; then
    local tom_pid="${WSTAT_WORKER_PID:-}"
    if [ -n "$tom_pid" ] && is_process_alive "$tom_pid"; then
      exclude_lines="${exclude_lines:+$exclude_lines,}${WSTAT_TASK_LINE}"
      exclude_count=$((exclude_count + 1))
      stale_count=$((stale_count - 1))
    fi
  fi

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

  # Remove first N [x] lines + their continuation lines
  awk -v n="$to_remove" '
    /^\[x\] / && removed < n { removed++; skipping=1; next }
    skipping && !/^\[[ xX!-]\] / && !/^#/ && !/^_{5,}/ && NF { next }
    { skipping=0; print }
  ' "$TASK_FILE" > "$TASK_FILE.tmp" && mv "$TASK_FILE.tmp" "$TASK_FILE"

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

# ─── Log Rotation ──────────────────────────────────────────────────────────

MAX_LOG_SIZE=1048576  # 1MB in bytes

rotate_log_if_needed() {
  local file="$1"
  [ -f "$file" ] || return
  local size
  size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
  if [ "${size:-0}" -gt "$MAX_LOG_SIZE" ]; then
    mv "$file" "${file}.old" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [BIG MAMMA] Log rotated (was ${size} bytes)" > "$file"
  fi
}

# ─── Retry Failed Tasks ───────────────────────────────────────────────────

retry_failed_tasks() {
  # Only retry when no pending/in-progress tasks remain and retries are allowed
  [ "$PENDING" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ] || return 1
  [ "$FAILED" -gt 0 ] || return 1

  local retried=0
  lock_tasks

  # Read each [-] line, hash its content, check if already retried
  local tmpfile="$TASK_FILE.retry.tmp"
  while IFS= read -r line; do
    if echo "$line" | grep -q '^\[-\] '; then
      local task_content
      task_content=$(echo "$line" | sed 's/^\[-\] //')
      local task_hash
      task_hash=$(echo "$task_content" | cksum | cut -d' ' -f1)

      if echo "$RETRIED_TASKS" | grep -qw "$task_hash"; then
        # Already retried this task — leave it as failed
        echo "$line"
      else
        # Retry: change [-] back to [ ]
        echo "[ ] $task_content"
        RETRIED_TASKS="${RETRIED_TASKS:+$RETRIED_TASKS }$task_hash"
        retried=$((retried + 1))
      fi
    else
      echo "$line"
    fi
  done < "$TASK_FILE" > "$tmpfile"

  if [ "$retried" -gt 0 ]; then
    mv "$tmpfile" "$TASK_FILE"
    unlock_tasks
    log "👩🏽🔄 Big Mamma recycled $retried failed task(s) for ONE more try."
    log "   \"Everybody deserves a second chance... but NOT a third.\""
    wake_worker
    ALL_DONE_LOGGED=false
    return 0
  else
    rm -f "$tmpfile"
    unlock_tasks
    return 1
  fi
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

# ─── Jerry (Parallel Worker) Management ───────────────────────────────────

fill_jerry_slots() {
  # Eagerly fill free Jerry slots with pending tasks — instant, no LLM analysis.
  # Worktree isolation + merge conflict handling provides safety; failures requeue.
  # This replaces the old analyze_for_parallelism() which required a slow claude -p
  # call per cycle, making it impossible to fill more than 1-2 slots at a time.
  local free_slots=0
  for ((i=0; i<MAX_PARALLEL; i++)); do
    [ "${P_ACTIVE[$i]}" = false ] && free_slots=$((free_slots + 1))
  done
  [ "$free_slots" -eq 0 ] && return 1
  [ "$PENDING" -lt 1 ] && return 1

  # Cooldown: don't re-scan if we just deployed (prevents spinning on same state)
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

  log "👩🏽🐭 Pending task(s) in '$ACTIVE_SECTION_NAME', $free_slots Jerry slot(s) free — filling them up!"

  # Reserve first pending task for Tom (unless Tom is already busy)
  local skip_first=1
  if is_claude_alive; then
    skip_first=0  # Tom is busy — Jerry can take everything
  fi

  local spawned=0
  local skipped=0
  while IFS= read -r candidate; do
    [ "$free_slots" -le 0 ] && break
    local line_num
    line_num=$(echo "$candidate" | cut -d: -f1)
    [ "$line_num" -lt "$ACTIVE_SECTION_START" ] && continue
    [ "$line_num" -gt "$ACTIVE_SECTION_END" ] && break

    # Leave first pending task for Tom's sequential queue
    if [ "$skip_first" -gt 0 ] && [ "$skipped" -lt "$skip_first" ]; then
      skipped=$((skipped + 1))
      continue
    fi

    local slot
    slot=$(find_free_slot) || break

    local task_desc
    task_desc=$(echo "$candidate" | sed 's/^[0-9]*:\[ \] //')

    # Read continuation lines (multi-line task descriptions)
    local _cnext=$(( line_num + 1 ))
    while [ "$_cnext" -le "$ACTIVE_SECTION_END" ]; do
      local _ccont
      _ccont=$(sed -n "${_cnext}p" "$TASK_FILE")
      if [ -z "$_ccont" ] || echo "$_ccont" | grep -qE '^\[[ xX!-]\] |^#+ |^_{5,}'; then
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

    spawn_parallel_worker "$slot" "$line_num" "$task_desc"
    # Only count as deployed if P_ACTIVE was actually set (spawn can fail on verify/worktree)
    if [ "${P_ACTIVE[$slot]}" = true ]; then
      spawned=$((spawned + 1))
      free_slots=$((free_slots - 1))
    else
      log "🐭⚠ Jerry #$slot failed to launch for line $line_num — slot still free, trying next task"
    fi
  done < <(grep -n '^\[ \] ' "$TASK_FILE" 2>/dev/null || true)

  PARALLEL_LAST_ANALYSIS=$now_ts

  if [ "$spawned" -gt 0 ]; then
    log "👩🏽🐭 Deployed $spawned Jerry(s)! \"Y'all better WORK, not just STAND there!\""
  fi
  return 0
}

spawn_parallel_worker() {
  local slot="$1"
  local task_line="$2"
  local task_desc="$3"
  local branch_name="parallel-${slot}-$(date +%s)"
  local worktree_dir=".worktrees/$branch_name"
  local status_file=".parallel-status-$slot"
  local log_file="claude-parallel-$slot.log"

  log "${_C_BLUE}▶ TASK STARTED ─── [Jerry #${slot}] #${task_line}: ${task_desc}${_C_RST}"

  # Mark task as in-progress (with race-condition guard)
  lock_tasks
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "${task_line}s/^\[ \] /[!] /" "$TASK_FILE"
  else
    sed -i "${task_line}s/^\[ \] /[!] /" "$TASK_FILE"
  fi
  # Verify the mark stuck (prevent race with Tom picking up the same task)
  local verify
  verify=$(sed -n "${task_line}p" "$TASK_FILE" 2>/dev/null)
  if ! echo "$verify" | grep -q '^\[!\] '; then
    unlock_tasks
    log "🐭⚠ Jerry #$slot: task at line $task_line already claimed. Skipping."
    return
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

  # Write Jerry's status (flatten desc for KEY=VALUE format)
  local safe_desc="${task_desc//$'\n'/ }"
  cat > "$status_file" <<EOF
STATE=running
SLOT=$slot
TASK_LINE=$task_line
TASK_DESC=$safe_desc
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

  log "   🐭 Jerry #$slot scurrying away (PID ${P_PIDS[$slot]}) in $worktree_dir"
}

check_parallel_workers() {
  for ((i=0; i<MAX_PARALLEL; i++)); do
    [ "${P_ACTIVE[$i]}" = true ] || continue

    if is_process_alive "${P_PIDS[$i]}"; then
      # Still running — periodic status
      local status_file=".parallel-status-$i"
      if [ -f "$status_file" ]; then
        # Heartbeat: refresh UPDATED so the dashboard knows Jerry is alive
        sed -i "s/^UPDATED=.*/UPDATED=$(date +%s)/" "$status_file" 2>/dev/null
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
      log "${_C_GREEN}✓ TASK DONE ─── [Jerry #${i}] #${P_TASK_LINES[$i]}: ${P_TASK_DESCS[$i]}${_C_RST}"
      merge_parallel_worker "$i"
    else
      log "${_C_RED}✗ TASK FAILED ─── [Jerry #${i}] #${P_TASK_LINES[$i]} (exit $p_exit): ${P_TASK_DESCS[$i]}${_C_RST}"
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

# Kill a process and all its children (tree kill on Windows)
kill_tree() {
  local pid="$1"
  if [ -f "/proc/$pid/winpid" ]; then
    local winpid
    winpid=$(cat "/proc/$pid/winpid" 2>/dev/null || true)
    if [ -n "$winpid" ]; then
      taskkill //T //F //PID "$winpid" > /dev/null 2>&1 && return 0
    fi
  fi
  kill "$pid" 2>/dev/null
}

cleanup_all_parallel() {
  for ((i=0; i<MAX_PARALLEL; i++)); do
    if [ "${P_ACTIVE[$i]}" = true ]; then
      [ -n "${P_PIDS[$i]}" ] && kill_tree "${P_PIDS[$i]}"
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

# ─── Read CLAUDE.md and Mamma Instructions ─────────────────────────────────

CLAUDE_MD_CONTENT=""
if [ -f "CLAUDE.md" ]; then
  CLAUDE_MD_CONTENT=$(cat "CLAUDE.md" 2>/dev/null | head -200)
  log "👩🏽📖 Big Mamma read the CLAUDE.md. She knows what's what."
else
  log "👩🏽 No CLAUDE.md found. Big Mamma's flying blind — but she's BEEN doing this."
fi

MAMMA_INSTRUCTIONS=""
if [ -f "$TASK_FILE" ]; then
  # Extract content between "## Mamma Instructions" and the separator line or next heading
  MAMMA_INSTRUCTIONS=$(awk '
    /^## Mamma Instructions/{ found=1; next }
    found && /^_{5,}|^## |^# /{ exit }
    found { print }
  ' "$TASK_FILE" 2>/dev/null | sed '/^<!--/,/-->$/d; /^$/d' | head -100)
  if [ -n "$MAMMA_INSTRUCTIONS" ]; then
    log "👩🏽📋 Mamma Instructions loaded. Big Mamma knows the PLAN."
  fi
fi

# ─── State ───────────────────────────────────────────────────────────────────

LAST_DONE_COUNT=$(count_done)
LAST_CHANGE_TIME=0
PENDING_COMMIT=false
CURRENT_ACTIVE_SECTION=""

# Cleanup on exit
cleanup_supervisor() {
  cleanup_all_parallel
  rm -f "$HIBERNATE_FILE"
  rm -rf "$LOCK_DIR"
  log "👩🏽 Big Mamma has left the building. Y'all are on your OWN now."
}
trap cleanup_supervisor EXIT
trap 'cleanup_supervisor; exit 0' INT TERM

# Start fresh
rm -f "$HIBERNATE_FILE"
rm -rf "$LOCK_DIR"
# Prune stale worktrees from previous runs (prevents git worktree add failures)
git worktree prune >> "$VERBOSE_LOG" 2>&1 || true

log "╔═══════════════════════════════════════════════════════╗"
log "║  👩🏽 Big Mamma's in the HOUSE! Everybody BEHAVE!       ║"
log "╚═══════════════════════════════════════════════════════╝"
log "Branch: $BRANCH"
log "Task file: $TASK_FILE"
log "Auto mode: ${AUTO_MODE:-off}"
log "CLAUDE.md: $([ -n "$CLAUDE_MD_CONTENT" ] && echo 'loaded ✓' || echo 'not found')"
log "Mamma Instructions: $([ -n "$MAMMA_INSTRUCTIONS" ] && echo 'loaded ✓' || echo 'none')"
log "Jerry slots: $MAX_PARALLEL"
log "Poll interval: ${POLL_INTERVAL}s"
log "Commit debounce: ${COMMIT_BATCH_WAIT}s"
log "Roll call: $(count_done) done, $(count_in_progress) in-progress, $(count_pending) pending, $(count_failed) failed"
log "\"Now let's get this house in ORDER.\""

# ─── Startup recovery: reset orphaned [!] tasks ─────────────────────────────
_update_task_counts
STARTUP_STALE=$_COUNT_IP
if [ "$STARTUP_STALE" -gt 0 ]; then
  log "👩🏽😤 $STARTUP_STALE task(s) stuck at [!] from last session! Nobody's working yet — resetting ALL."
  log "   \"Lord have mercy, y'all left the STOVE on!\""
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' 's/^\[!\] /[ ] /' "$TASK_FILE"
  else
    sed -i 's/^\[!\] /[ ] /' "$TASK_FILE"
  fi
  LAST_DONE_COUNT=$(count_done)
  log "   👩🏽✓ Reset $STARTUP_STALE orphaned task(s) back to pending. Fresh start."
fi

# ─── Main loop ───────────────────────────────────────────────────────────────

while true; do
  # Single pass through TASKS.md for all counts (avoids 4 separate grep subshells)
  _update_task_counts
  CURRENT_DONE=$_COUNT_DONE
  IN_PROGRESS=$_COUNT_IP
  PENDING=$_COUNT_PENDING
  FAILED=$_COUNT_FAILED
  NOW=$(date +%s)

  # Track active section transitions (section-aware delegation)
  _sep=$(grep -n '^_{5,}' "$TASK_FILE" 2>/dev/null | head -1 | cut -d: -f1)
  _sep="${_sep:-0}"
  if find_active_section "$TASK_FILE" "$_sep"; then
    if [ "$ACTIVE_SECTION_NAME" != "$CURRENT_ACTIVE_SECTION" ]; then
      if [ -n "$CURRENT_ACTIVE_SECTION" ] && [ "$CURRENT_ACTIVE_SECTION" != "(all tasks)" ]; then
        log "👩🏽✅ Section complete: $CURRENT_ACTIVE_SECTION"
      fi
      CURRENT_ACTIVE_SECTION="$ACTIVE_SECTION_NAME"
      if [ "$ACTIVE_SECTION_NAME" != "(all tasks)" ]; then
        log "👩🏽📋 Now working on: $ACTIVE_SECTION_NAME"
      fi
    fi
  fi

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

  # ── Deploy Jerrys for pending tasks (eager — no LLM bottleneck) ──
  if [ "$PENDING" -gt 0 ]; then
    fill_jerry_slots
  fi

  # ── Stale task detection (status-aware) ──
  if [ "$IN_PROGRESS" -gt 0 ]; then
    # Cap check: more [!] tasks than physically possible = guaranteed stale
    MAX_POSSIBLE=$((1 + MAX_PARALLEL))
    if [ "$IN_PROGRESS" -gt "$MAX_POSSIBLE" ]; then
      log "👩🏽🧮 HOLD UP! $IN_PROGRESS tasks at [!] but I only got $MAX_POSSIBLE workers (1 Tom + $MAX_PARALLEL Jerry)!"
      log "   \"I can COUNT, children! That math don't ADD UP!\" Recovering stale tasks NOW."
      recover_stale_tasks
      # Re-count after recovery
      _update_task_counts
      IN_PROGRESS=$_COUNT_IP
      PENDING=$_COUNT_PENDING
      sleep "$POLL_INTERVAL"
      continue
    fi

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
          if [ -n "$QA_CHECKING_TASKS" ]; then
            log "👩🏽⏳ Spike's still sniffing around... hold your horses, Tom. ${_C_YELLOW}[QA: ${QA_CHECKING_TASKS}]${_C_RST}"
          else
            log "👩🏽⏳ Spike's still sniffing around... hold your horses, Tom."
          fi
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

    # Try retrying failed tasks before declaring done
    if [ "$FAILED" -gt 0 ] && retry_failed_tasks; then
      sleep "$POLL_INTERVAL"
      continue
    fi

    # Log "all done" only ONCE to prevent spam (was 973 spam lines in App B)
    if [ "$ALL_DONE_LOGGED" = false ]; then
      if [ "$FAILED" -gt 0 ]; then
        log "👩🏽 All tasks processed. $CURRENT_DONE done, $FAILED FAILED (retries exhausted). Tom is resting."
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
      ALL_DONE_LOGGED=true
      IDLE_SHUTDOWN_START=$NOW
    fi

    # ── Graceful idle shutdown (no tasks for IDLE_SHUTDOWN_AFTER seconds) ──
    if [ "$IDLE_SHUTDOWN_START" -gt 0 ]; then
      idle_elapsed=$(( NOW - IDLE_SHUTDOWN_START ))
      if [ "$idle_elapsed" -ge "$IDLE_SHUTDOWN_AFTER" ]; then
        log "👩🏽💤 No new tasks for $((idle_elapsed / 60)) minutes. Big Mamma's closing up shop."
        log "   \"The house runs itself now. Good night, y'all.\""
        exit 0
      fi
    fi
  else
    # Tasks appeared — reset idle state
    ALL_DONE_LOGGED=false
    IDLE_SHUTDOWN_START=0
  fi

  # ── Periodic log rotation ──
  if [ $((ALIVE_TICKS % 40)) -eq 0 ] && [ "$ALIVE_TICKS" -gt 0 ]; then
    rotate_log_if_needed "$LOG_FILE"
    rotate_log_if_needed "$VERBOSE_LOG"
  fi

  sleep "$POLL_INTERVAL"
done
