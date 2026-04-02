#!/usr/bin/env bash
# claude-qa.sh — 🐶 Spike the Bulldog: quality enforcer
#
# "Listen here, pussycat. You make a mess, I make you CLEAN it up."
#                                                        — Spike
#
# Monitors TASKS.md for completed tasks and runs build/lint/type checks.
# If checks fail, Spike sends Tom right back to fix his mess.
#
# Usage:
#   ./claude-qa.sh                  # uses TASKS.md
#   ./claude-qa.sh TASKS.md         # custom task file

set -u

TASK_FILE="${1:-TASKS.md}"
LOG_FILE="claude-qa.log"
STATUS_FILE=".qa-status"
WORKER_STATUS_FILE=".worker-status"
MAX_PARALLEL=2
POLL_INTERVAL=20
LOCK_DIR=".tasks.lock"
MAX_FIX_RETRIES=3
FIX_ATTEMPT=0
LAST_CHECKED_DONE=0
QA_ERRORS=""

if [ ! -f "$TASK_FILE" ]; then
  echo "ERROR: Task file '$TASK_FILE' not found. Spike has nothing to sniff!"
  exit 1
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [SPIKE] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

write_qa_status() {
  local state="$1"
  local errors="${2:-}"
  local validated_done="${3:-}"
  cat > "$STATUS_FILE" <<EOF
STATE=$state
QA_PID=$$
LAST_CHECK=$(date +%s)
FIX_ATTEMPT=$FIX_ATTEMPT
VALIDATED_DONE=$validated_done
ERRORS=$errors
EOF
}

count_done() {
  local n
  n=$(grep -c '^\[x\] ' "$TASK_FILE" 2>/dev/null) || true
  echo "${n:-0}"
}

# ─── File locking ────────────────────────────────────────────────────────────

lock_tasks() {
  local attempts=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 0.5
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 20 ]; then
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" 2>/dev/null || true
      return
    fi
  done
}

unlock_tasks() {
  rm -rf "$LOCK_DIR"
}

# ─── Worker awareness ───────────────────────────────────────────────────────

is_any_worker_active() {
  # Check if Tom is busy chasing something
  if [ -f "$WORKER_STATUS_FILE" ]; then
    local state
    state=$(grep '^STATE=' "$WORKER_STATUS_FILE" 2>/dev/null | cut -d= -f2)
    [ "$state" = "running" ] && return 0
  fi
  # Check if any Jerrys are scurrying around
  for ((i=0; i<MAX_PARALLEL; i++)); do
    local pfile=".parallel-status-$i"
    if [ -f "$pfile" ]; then
      local pstate
      pstate=$(grep '^STATE=' "$pfile" 2>/dev/null | cut -d= -f2)
      [ "$pstate" = "running" ] && return 0
    fi
  done
  return 1
}

# ─── Fix task injection ─────────────────────────────────────────────────────

inject_fix_task() {
  local errors="$1"
  lock_tasks
  echo "" >> "$TASK_FILE"
  echo "[ ] [AUTO-FIX] Fix the following build/type errors found by QA (attempt ${FIX_ATTEMPT}/${MAX_FIX_RETRIES}). Do NOT add new features — only fix these errors. Errors: $errors" >> "$TASK_FILE"
  unlock_tasks
  log "🐶💢 Spike drops a fix task in Tom's bowl: \"CLEAN. THIS. UP. NOW.\""
}

# ─── Quality checks ─────────────────────────────────────────────────────────

run_checks() {
  log "🐶🔍 *sniff sniff* Spike is inspecting the premises..."

  # Let Claude analyze the project and run whatever checks are appropriate.
  # This works for any stack: web, mobile, game dev, backend, ML, etc.
  CLAUDE_QA="claude -p --dangerously-skip-permissions"

  local qa_output=""
  qa_output=$($CLAUDE_QA "You are a QA validator. Analyze this project and run the appropriate build, compile, lint, and type-check commands to verify correctness.

Rules:
- Look at the project files to determine the tech stack (could be anything: TypeScript, C#/Unity, Python, Rust, Go, Java, C++, etc.)
- Run ONLY non-destructive validation commands (compile checks, lint, type checks, schema validation)
- Do NOT run tests, do NOT install dependencies, do NOT modify any files
- Do NOT run dev servers or anything that would hang
- If there are no errors, respond with exactly: QA_RESULT:PASS
- If there ARE errors, respond with exactly: QA_RESULT:FAIL followed by a summary of errors (max 30 lines)
- Always start your final verdict line with QA_RESULT:PASS or QA_RESULT:FAIL" 2>&1) || true

  if echo "$qa_output" | grep -q "QA_RESULT:PASS"; then
    log "🐶✓ *tail wag* All checks clean!"
    QA_ERRORS=""
    return 0
  elif echo "$qa_output" | grep -q "QA_RESULT:FAIL"; then
    local errors
    errors=$(echo "$qa_output" | sed -n '/QA_RESULT:FAIL/,$p' | tail -n +2 | head -30)
    log "🐶💢 GRRR! Errors found! WHO DID THIS?!"
    QA_ERRORS="$errors"
    return 1
  else
    # Claude didn't return a clear verdict — treat as pass with warning
    log "🐶❓ Spike couldn't determine a clear verdict — allowing pass with warning"
    QA_ERRORS=""
    return 0
  fi
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────

cleanup_qa() {
  rm -f "$STATUS_FILE"
}

trap cleanup_qa EXIT INT TERM

# ─── Startup ─────────────────────────────────────────────────────────────────

LAST_CHECKED_DONE=$(count_done)
write_qa_status "idle"

log "╔═══════════════════════════════════════════════════════╗"
log "║  🐶 Spike the Bulldog — Quality Enforcer              ║"
log "║  Watching: $TASK_FILE"
log "║  \"Nobody ships bugs on MY watch. Nobody.\"             ║"
log "╚═══════════════════════════════════════════════════════╝"
log "Initial done count: $LAST_CHECKED_DONE"

# ─── Main loop ───────────────────────────────────────────────────────────────

while true; do
  CURRENT_DONE=$(count_done)

  if [ "$CURRENT_DONE" -gt "$LAST_CHECKED_DONE" ]; then
    NEW_COMPLETIONS=$((CURRENT_DONE - LAST_CHECKED_DONE))
    log "🐶👀 Spike's ears perk up! $NEW_COMPLETIONS new completed task(s). Time to inspect!"

    # Wait for workers to finish current task to avoid checking intermediate state
    WAIT_CYCLES=0
    while is_any_worker_active && [ "$WAIT_CYCLES" -lt 40 ]; do
      if [ "$WAIT_CYCLES" -eq 0 ]; then
        log "🐶⏳ Spike sits by the door, one eye open... waiting for Tom to finish..."
      fi
      sleep 5
      WAIT_CYCLES=$((WAIT_CYCLES + 1))
    done

    write_qa_status "checking"

    if run_checks; then
      log "🐶😊 *happy bark* ALL CLEAR! Spike approves! ($CURRENT_DONE task(s) validated)"
      log "   \"That's a good cat. ...don't let it go to your head.\""
      write_qa_status "passed" "" "$CURRENT_DONE"
      LAST_CHECKED_DONE=$CURRENT_DONE
      FIX_ATTEMPT=0
    else
      FIX_ATTEMPT=$((FIX_ATTEMPT + 1))
      TRUNCATED_ERRORS=$(echo "$QA_ERRORS" | head -30)

      if [ "$FIX_ATTEMPT" -ge "$MAX_FIX_RETRIES" ]; then
        log "🐶😤 *exhausted sigh* Spike tried $MAX_FIX_RETRIES times. Fine. FINE."
        log "   \"I'm too old for this... ship it with warnings, I don't even care anymore.\""
        write_qa_status "passed_with_warnings" "$TRUNCATED_ERRORS" "$CURRENT_DONE"
        LAST_CHECKED_DONE=$CURRENT_DONE
        FIX_ATTEMPT=0
      else
        log "🐶🦴 Spike GROWLS! QA FAILED (attempt $FIX_ATTEMPT/$MAX_FIX_RETRIES)!"
        log "   \"Listen here, Tom. You FIX this, or I fix YOU.\""
        write_qa_status "failed" "$TRUNCATED_ERRORS"
        inject_fix_task "$TRUNCATED_ERRORS"
        # Don't update LAST_CHECKED_DONE — will re-check when fix completes
      fi
    fi
  fi

  sleep "$POLL_INTERVAL"
done
