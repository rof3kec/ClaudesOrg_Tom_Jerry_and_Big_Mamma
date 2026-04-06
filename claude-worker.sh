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
#   [q] Ready for QA               <- Tom caught it, Spike needs to check
#   [x] Done                        <- Spike approved it
#   [!] In progress                 <- Tom's chasing it right now
#   [-] Failed                      <- Tom ran into a wall

set -u

# ─── Source shared library ───────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TASK_FILE="${1:-TASKS.md}"
AUTO_MODE="${2:-}"
LOG_FILE="claude-worker.log"
LOG_PREFIX="[TOM]"

source "$SCRIPT_DIR/lib/house-common.sh"

# ─── Worker-specific config ─────────────────────────────────────────────────

VERBOSE_LOG="claude-worker-output.log"
POLL_INTERVAL=10           # seconds between idle checks
HIBERNATE_POLL=30          # seconds between checks while hibernating
PID_FILE=".claude-worker.pid"
STATUS_FILE=".worker-status"
RECENTLY_COMPLETED=""      # dedup guard: hashes of recently completed tasks

if [ ! -f "$TASK_FILE" ]; then
  echo "ERROR: Task file '$TASK_FILE' not found. Tom has nothing to chase!"
  exit 1
fi

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

# ─── Cleanup on exit ─────────────────────────────────────────────────────────

CLAUDE_PID=""

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

house_log "╔═══════════════════════════════════════════════════════╗"
house_log "║  🐱 Tom the Cat — reporting for duty!                 ║"
house_log "║  Watching: $TASK_FILE"
house_log "║  \"Just point me at the tasks and stand back.\"         ║"
house_log "╚═══════════════════════════════════════════════════════╝"
if [ "$AUTO_MODE" = "--auto" ]; then
  house_log "⚡ Tom is in FERAL MODE (--dangerously-skip-permissions). No cage can hold him!"
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
        house_log "🐱💤 *yaaawn* Tom curls up on the windowsill... zzz..."
        house_log "   (Don't tell Big Mamma I'm napping on the job)"
        IDLE_LOGGED="hibernate"
      fi
      write_status "hibernating"
      while [ -f "$HIBERNATE_FILE" ]; do
        sleep "$HIBERNATE_POLL"
      done
      house_log "🐱⏰ *CRASH* Tom jolts awake! WHAT?! WHO?! ...oh. New tasks. Right."
      IDLE_LOGGED=""
      continue
    fi
    write_status "idle"
    if [ "${IDLE_LOGGED:-}" != "idle" ]; then
      house_log "🐱 Tom's sitting by the window, looking bored... no tasks in sight"
      house_log "   *flicks tail impatiently*"
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
    if [ -z "$_cont" ] || echo "$_cont" | grep -qE '^\[[ xXqQ!-]\] |^#+ |^_{5,}'; then
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
    house_log "🐱⚠ Tom already caught this one! Skipping duplicate: $(short "$TASK_DESC")"
    # Mark it ready for QA since we already completed it
    lock_tasks
    sedi "${LINE_NUM}s/^\[ \] /[q] /" "$TASK_FILE"
    unlock_tasks
    sleep 1
    continue
  fi

  # Mark task as in-progress (while still holding lock)
  sedi "${LINE_NUM}s/^\[ \] /[!] /" "$TASK_FILE"

  # Verify the mark stuck (prevent race condition)
  VERIFY=$(sed -n "${LINE_NUM}p" "$TASK_FILE" 2>/dev/null)
  if ! echo "$VERIFY" | grep -q '^\[!\] '; then
    unlock_tasks
    house_log "🐱⚠ Task mark didn't stick on line $LINE_NUM. Skipping to avoid double-pickup."
    sleep 1
    continue
  fi
  unlock_tasks

  # We have a task — reset idle state
  IDLE_LOGGED=""
  TASK_START_TIME=$(date +%s)
  # Write status IMMEDIATELY with task desc (fixes "unknown task" in Big Mamma's logs)
  write_status "running" "$LINE_NUM" "$TASK_DESC" "$TASK_START_TIME"
  house_log "${_C_BLUE}▶ TASK STARTED ─── [Tom] #${LINE_NUM}: ${TASK_DESC}${_C_RST}"

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
    house_log "${_C_GREEN}✓ TASK DONE ─── [Tom] #${LINE_NUM}: ${TASK_DESC}${_C_RST}"
    sedi "${LINE_NUM}s/^\[!\] /[q] /" "$TASK_FILE"
    # Add to dedup set so we don't re-process if task appears again
    RECENTLY_COMPLETED="${RECENTLY_COMPLETED:+$RECENTLY_COMPLETED }$TASK_HASH"
  else
    house_log "${_C_RED}✗ TASK FAILED ─── [Tom] #${LINE_NUM} (exit $EXIT_CODE): ${TASK_DESC}${_C_RST}"
    sedi "${LINE_NUM}s/^\[!\] /[-] /" "$TASK_FILE"
  fi
  unlock_tasks
  write_status "idle"

  # Small pause between tasks (even cats need to catch their breath)
  sleep 2
done
