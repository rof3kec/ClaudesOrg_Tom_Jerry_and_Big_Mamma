#!/usr/bin/env bash
# claude-worker.sh — 🐱 Tom the Cat: background task chaser extraordinaire
#
# "I don't always chase tasks... actually, yes I do. It's literally my job."
#                                                            — Tom
#
# Usage:
#   ./claude-worker.sh                  # uses TASKS.md in current dir
#   ./claude-worker.sh myfile.md        # custom task file
#   ./claude-worker.sh TASKS.md --auto  # skip permission prompts (Tom goes FERAL)
#
# Task format in TASKS.md:
#   [ ] Task description here      <- Tom's prey
#   [x] Done                        <- Tom caught it
#   [!] In progress                 <- Tom's chasing it right now
#   [-] Failed                      <- Tom ran into a wall

set -u

TASK_FILE="${1:-TASKS.md}"
AUTO_MODE="${2:-}"
LOG_FILE="claude-worker.log"
VERBOSE_LOG="claude-worker-output.log"
POLL_INTERVAL=10           # seconds between idle checks
HIBERNATE_FILE=".worker-hibernate"
HIBERNATE_POLL=30          # seconds between checks while hibernating
LOCK_DIR=".tasks.lock"
PID_FILE=".claude-worker.pid"
STATUS_FILE=".worker-status"
RECENTLY_COMPLETED=""      # dedup guard: hashes of recently completed tasks
SEPARATOR_SEEN=false       # track if we've passed the ____ separator in TASKS.md

# ANSI colors for task event visibility (rendered by tail -f in terminal)
_C_RST=$'\033[0m'
_C_BLUE=$'\033[1;94m'
_C_GREEN=$'\033[1;92m'
_C_RED=$'\033[1;91m'

if [ ! -f "$TASK_FILE" ]; then
  echo "ERROR: Task file '$TASK_FILE' not found. Tom has nothing to chase!"
  exit 1
fi

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [TOM] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

short() {
  # Truncate to 10 words + (...)
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

# ─── Status file (lets Big Mamma know what Tom is doing) ────────────────────

write_status() {
  local state="$1"
  local task_line="${2:-}"
  local task_desc="${3:-}"
  task_desc="${task_desc//$'\n'/ }"
  local started="${4:-$(date +%s)}"
  cat > "$STATUS_FILE" <<EOF
STATE=$state
WORKER_PID=$$
CLAUDE_PID=${CLAUDE_PID:-}
TASK_LINE=$task_line
TASK_DESC=$task_desc
TASK_STARTED=$started
UPDATED=$(date +%s)
EOF
}

# ─── File locking (mkdir is atomic on all platforms) ──────────────────────────

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

# ─── Cleanup on exit ─────────────────────────────────────────────────────────

CLAUDE_PID=""

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

cleanup_worker() {
  if [ -n "$CLAUDE_PID" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill_tree "$CLAUDE_PID"
  fi
  rm -f "$PID_FILE"
  rm -f "$STATUS_FILE"
  rm -rf "$LOCK_DIR"
}

trap cleanup_worker EXIT
trap 'cleanup_worker; exit 0' INT TERM

# ─── Startup ──────────────────────────────────────────────────────────────────

# Clean up stale lock from previous crash
rm -rf "$LOCK_DIR"

log "╔═══════════════════════════════════════════════════════╗"
log "║  🐱 Tom the Cat — reporting for duty!                 ║"
log "║  Watching: $TASK_FILE"
log "║  \"Just point me at the tasks and stand back.\"         ║"
log "╚═══════════════════════════════════════════════════════╝"
if [ "$AUTO_MODE" = "--auto" ]; then
  log "⚡ Tom is in FERAL MODE (--dangerously-skip-permissions). No cage can hold him!"
fi

write_status "idle"

while true; do
  # Atomically find and claim the first pending task
  lock_tasks

  # Find the separator line number (tasks only valid after it)
  SEPARATOR_LINE=$(grep -n '^_{5,}' "$TASK_FILE" 2>/dev/null | head -1 | cut -d: -f1)
  SEPARATOR_LINE="${SEPARATOR_LINE:-0}"

  # Find first pending task within the active section (section-aware delegation)
  MATCH=""
  CAND_LINE=""
  CAND_DESC=""
  if find_active_section "$TASK_FILE" "$SEPARATOR_LINE"; then
    while IFS= read -r candidate; do
      CAND_LINE=$(echo "$candidate" | cut -d: -f1)
      if [ "$CAND_LINE" -ge "$ACTIVE_SECTION_START" ] && [ "$CAND_LINE" -le "$ACTIVE_SECTION_END" ]; then
        # Validate it's a real task (not a status description or metadata)
        CAND_DESC=$(echo "$candidate" | sed 's/^[0-9]*:\[ \] //')
        # Skip lines that look like status text, not real tasks
        if echo "$CAND_DESC" | grep -qiE '^(pending|done|in progress|failed|waiting)(\s|$)'; then
          continue
        fi
        MATCH="$candidate"
        break
      fi
    done < <(grep -n '^\[ \] ' "$TASK_FILE" 2>/dev/null || true)
  fi

  if [ -z "$MATCH" ]; then
    unlock_tasks
    # Check if Big Mamma has put Tom in hibernation
    if [ -f "$HIBERNATE_FILE" ]; then
      if [ "${IDLE_LOGGED:-}" != "hibernate" ]; then
        log "🐱💤 *yaaawn* Tom curls up on the windowsill... zzz..."
        log "   (Don't tell Big Mamma I'm napping on the job)"
        IDLE_LOGGED="hibernate"
      fi
      write_status "hibernating"
      while [ -f "$HIBERNATE_FILE" ]; do
        sleep "$HIBERNATE_POLL"
      done
      log "🐱⏰ *CRASH* Tom jolts awake! WHAT?! WHO?! ...oh. New tasks. Right."
      IDLE_LOGGED=""
      continue
    fi
    write_status "idle"
    if [ "${IDLE_LOGGED:-}" != "idle" ]; then
      log "🐱 Tom's sitting by the window, looking bored... no tasks in sight"
      log "   *flicks tail impatiently*"
      IDLE_LOGGED="idle"
    fi
    sleep "$POLL_INTERVAL"
    continue
  fi

  LINE_NUM=$(echo "$MATCH" | cut -d: -f1)
  TASK_DESC=$(echo "$MATCH" | sed 's/^[0-9]*:\[ \] //')

  # Read continuation lines (multi-line task descriptions)
  _next=$((LINE_NUM + 1))
  while [ "$_next" -le "$ACTIVE_SECTION_END" ]; do
    _cont=$(sed -n "${_next}p" "$TASK_FILE")
    if [ -z "$_cont" ] || echo "$_cont" | grep -qE '^\[[ xX!-]\] |^#+ |^_{5,}'; then
      break
    fi
    TASK_DESC="${TASK_DESC}
${_cont}"
    _next=$((_next + 1))
  done

  # Dedup guard: skip tasks we already completed this session
  TASK_HASH=$(echo "$TASK_DESC" | cksum | cut -d' ' -f1)
  if echo "$RECENTLY_COMPLETED" | grep -qw "$TASK_HASH"; then
    unlock_tasks
    log "🐱⚠ Tom already caught this one! Skipping duplicate: $(short "$TASK_DESC")"
    # Mark it done since we already completed it
    lock_tasks
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "${LINE_NUM}s/^\[ \] /[x] /" "$TASK_FILE"
    else
      sed -i "${LINE_NUM}s/^\[ \] /[x] /" "$TASK_FILE"
    fi
    unlock_tasks
    sleep 1
    continue
  fi

  # Mark task as in-progress (while still holding lock)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "${LINE_NUM}s/^\[ \] /[!] /" "$TASK_FILE"
  else
    sed -i "${LINE_NUM}s/^\[ \] /[!] /" "$TASK_FILE"
  fi

  # Verify the mark stuck (prevent race condition from App A Session 2)
  VERIFY=$(sed -n "${LINE_NUM}p" "$TASK_FILE" 2>/dev/null)
  if ! echo "$VERIFY" | grep -q '^\[!\] '; then
    unlock_tasks
    log "🐱⚠ Task mark didn't stick on line $LINE_NUM. Skipping to avoid double-pickup."
    sleep 1
    continue
  fi
  unlock_tasks

  # We have a task — reset idle state
  IDLE_LOGGED=""
  TASK_START_TIME=$(date +%s)
  # Write status IMMEDIATELY with task desc (fixes "unknown task" in Big Mamma's logs)
  write_status "running" "$LINE_NUM" "$TASK_DESC" "$TASK_START_TIME"
  log "${_C_BLUE}▶ TASK STARTED ─── [Tom] #${LINE_NUM}: ${TASK_DESC}${_C_RST}"

  # Build claude command
  CLAUDE_CMD="claude -p"
  if [ "$AUTO_MODE" = "--auto" ]; then
    CLAUDE_CMD="$CLAUDE_CMD --dangerously-skip-permissions"
  fi

  # Run Claude on the task — track PID so Big Mamma can check liveness
  EXIT_CODE=0
  set +e
  $CLAUDE_CMD "$TASK_DESC" >> "$VERBOSE_LOG" 2>&1 &
  CLAUDE_PID=$!
  echo "$CLAUDE_PID" > "$PID_FILE"
  write_status "running" "$LINE_NUM" "$TASK_DESC" "$TASK_START_TIME"

  # Heartbeat: refresh UPDATED timestamp every 30s so the dashboard
  # knows Tom is still alive during long-running tasks
  while kill -0 "$CLAUDE_PID" 2>/dev/null; do
    sleep 30
    if kill -0 "$CLAUDE_PID" 2>/dev/null; then
      write_status "running" "$LINE_NUM" "$TASK_DESC" "$TASK_START_TIME"
    fi
  done
  wait "$CLAUDE_PID"
  EXIT_CODE=$?
  CLAUDE_PID=""
  rm -f "$PID_FILE"
  set -e

  # Mark task result (with lock to prevent race with Big Mamma)
  lock_tasks
  if [ "$EXIT_CODE" -eq 0 ]; then
    log "${_C_GREEN}✓ TASK DONE ─── [Tom] #${LINE_NUM}: ${TASK_DESC}${_C_RST}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "${LINE_NUM}s/^\[!\] /[x] /" "$TASK_FILE"
    else
      sed -i "${LINE_NUM}s/^\[!\] /[x] /" "$TASK_FILE"
    fi
    # Add to dedup set so we don't re-process if task appears again
    RECENTLY_COMPLETED="${RECENTLY_COMPLETED:+$RECENTLY_COMPLETED }$TASK_HASH"
  else
    log "${_C_RED}✗ TASK FAILED ─── [Tom] #${LINE_NUM} (exit $EXIT_CODE): ${TASK_DESC}${_C_RST}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "${LINE_NUM}s/^\[!\] /[-] /" "$TASK_FILE"
    else
      sed -i "${LINE_NUM}s/^\[!\] /[-] /" "$TASK_FILE"
    fi
  fi
  unlock_tasks
  write_status "idle"

  # Small pause between tasks (even cats need to catch their breath)
  sleep 2
done
