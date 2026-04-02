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

# ─── Status file (lets Big Mamma know what Tom is doing) ────────────────────

write_status() {
  local state="$1"
  local task_line="${2:-}"
  local task_desc="${3:-}"
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

cleanup_worker() {
  if [ -n "$CLAUDE_PID" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    kill "$CLAUDE_PID" 2>/dev/null
  fi
  rm -f "$PID_FILE"
  rm -f "$STATUS_FILE"
  rm -rf "$LOCK_DIR"
}

trap cleanup_worker EXIT INT TERM

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
  MATCH=$(grep -n '^\[ \] ' "$TASK_FILE" | head -1 || true)

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

  # Mark task as in-progress (while still holding lock)
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "${LINE_NUM}s/^\[ \] /[!] /" "$TASK_FILE"
  else
    sed -i "${LINE_NUM}s/^\[ \] /[!] /" "$TASK_FILE"
  fi
  unlock_tasks

  # We have a task — reset idle state
  IDLE_LOGGED=""
  TASK_START_TIME=$(date +%s)
  write_status "running" "$LINE_NUM" "$TASK_DESC" "$TASK_START_TIME"
  log "🐱🏃 Tom POUNCES on task #${LINE_NUM}: $(short "$TASK_DESC")"
  log "   *dramatic chase music intensifies*"

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
  wait "$CLAUDE_PID"
  EXIT_CODE=$?
  CLAUDE_PID=""
  rm -f "$PID_FILE"
  set -e

  # Mark task result (with lock to prevent race with Big Mamma)
  lock_tasks
  if [ "$EXIT_CODE" -eq 0 ]; then
    log "🐱😼 Tom CAUGHT it! Task DEMOLISHED: $(short "$TASK_DESC")"
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' "${LINE_NUM}s/^\[!\] /[x] /" "$TASK_FILE"
    else
      sed -i "${LINE_NUM}s/^\[!\] /[x] /" "$TASK_FILE"
    fi
  else
    log "🐱💥 *SPLAT* Tom ran face-first into a wall! (exit $EXIT_CODE): $(short "$TASK_DESC")"
    log "   *accordion sound effect* ...that's gonna leave a mark."
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
