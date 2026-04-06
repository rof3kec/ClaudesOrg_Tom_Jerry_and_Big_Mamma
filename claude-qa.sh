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

# ─── Source shared library ───────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TASK_FILE="${1:-TASKS.md}"
LOG_FILE="claude-qa.log"
LOG_PREFIX="[SPIKE]"

source "$SCRIPT_DIR/lib/house-common.sh"

# ─── QA-specific config ─────────────────────────────────────────────────────

STATUS_FILE=".qa-status"
MAX_PARALLEL=$(cat .house-jerries 2>/dev/null || echo 2)
POLL_INTERVAL=20
MAX_FIX_RETRIES=3
FIX_ATTEMPT=0
LAST_CHECKED_DONE=0
QA_ERRORS=""
QA_DEBOUNCE=30             # wait this many seconds after last completion before QA
QA_PENDING_SINCE=0         # timestamp when we first noticed new completions

if [ ! -f "$TASK_FILE" ]; then
  echo "ERROR: Task file '$TASK_FILE' not found. Spike has nothing to sniff!"
  exit 1
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

write_qa_status() {
  local state="$1"
  local errors="${2:-}"
  local validated_done="${3:-}"
  local checking_tasks="${4:-}"
  cat > "$STATUS_FILE" <<EOF
STATE=$state
QA_PID=$$
LAST_CHECK=$(date +%s)
FIX_ATTEMPT=$FIX_ATTEMPT
VALIDATED_DONE=$validated_done
CHECKING_TASKS=$checking_tasks
ERRORS=$errors
EOF
}

get_recent_qa_tasks() {
  # Return the descriptions of QA-ready tasks
  local all_qa
  all_qa=$(grep '^\[q\] ' "$TASK_FILE" 2>/dev/null | sed 's/^\[q\] //')
  # Truncate each line and join with " | "
  echo "$all_qa" | head -5 | cut -c1-60 | paste -sd'|' -
}

count_qa_ready() {
  local n
  n=$(grep -c '^\[q\] ' "$TASK_FILE" 2>/dev/null) || true
  echo "${n:-0}"
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
  house_log "🐶💢 Spike drops a fix task in Tom's bowl: \"CLEAN. THIS. UP. NOW.\""
}

# ─── Quality checks ─────────────────────────────────────────────────────────

run_checks() {
  house_log "🐶🔍 *sniff sniff* Spike is inspecting the premises..."

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
    house_log "🐶✓ *tail wag* All checks clean!"
    QA_ERRORS=""
    return 0
  elif echo "$qa_output" | grep -q "QA_RESULT:FAIL"; then
    local errors
    errors=$(echo "$qa_output" | sed -n '/QA_RESULT:FAIL/,$p' | tail -n +2 | head -30)
    house_log "🐶💢 GRRR! Errors found! WHO DID THIS?!"
    QA_ERRORS="$errors"
    return 1
  else
    # Claude didn't return a clear verdict — treat as pass with warning
    house_log "🐶❓ Spike couldn't determine a clear verdict — allowing pass with warning"
    QA_ERRORS=""
    return 0
  fi
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────

cleanup_qa() {
  rm -f "$STATUS_FILE"
}

trap cleanup_qa EXIT
trap 'cleanup_qa; exit 0' INT TERM

# ─── Startup ─────────────────────────────────────────────────────────────────

LAST_CHECKED_QA=$(count_qa_ready)
write_qa_status "idle"

house_log "╔═══════════════════════════════════════════════════════╗"
house_log "║  🐶 Spike the Bulldog — Quality Enforcer              ║"
house_log "║  Watching: $TASK_FILE"
house_log "║  \"Nobody ships bugs on MY watch. Nobody.\"             ║"
house_log "╚═══════════════════════════════════════════════════════╝"
house_log "Initial QA-ready count: $LAST_CHECKED_QA"

# ─── Main loop ───────────────────────────────────────────────────────────────

while true; do
  CURRENT_QA=$(count_qa_ready)
  NOW_TS=$(date +%s)

  if [ "$CURRENT_QA" -gt "$LAST_CHECKED_QA" ] || { [ "$CURRENT_QA" -gt 0 ] && [ "$LAST_CHECKED_QA" -eq 0 ]; }; then
    # New QA-ready tasks detected — start/reset the debounce timer
    if [ "$QA_PENDING_SINCE" -eq 0 ]; then
      house_log "🐶👀 Spike's ears perk up! $CURRENT_QA task(s) ready for QA. Time to inspect!"
      QA_PENDING_SINCE=$NOW_TS
    fi

    # Debounce: wait for QA_DEBOUNCE seconds of stability before checking
    # This prevents running QA on every single task during rapid sequential execution
    DEBOUNCE_ELAPSED=$((NOW_TS - QA_PENDING_SINCE))
    if [ "$DEBOUNCE_ELAPSED" -lt "$QA_DEBOUNCE" ]; then
      # Check if more tasks are still completing (reset timer)
      sleep "$POLL_INTERVAL"
      NEW_QA=$(count_qa_ready)
      if [ "$NEW_QA" -gt "$CURRENT_QA" ]; then
        QA_PENDING_SINCE=$NOW_TS  # reset debounce — more tasks completing
        house_log "🐶⏳ More tasks landing in QA... Spike resets his sniff timer."
      fi
      continue
    fi

    # Debounce expired — also wait for workers to finish current task
    WAIT_CYCLES=0
    while is_any_worker_active && [ "$WAIT_CYCLES" -lt 40 ]; do
      if [ "$WAIT_CYCLES" -eq 0 ]; then
        house_log "🐶⏳ Spike sits by the door, one eye open... waiting for Tom to finish..."
      fi
      sleep 5
      WAIT_CYCLES=$((WAIT_CYCLES + 1))
    done

    # Re-read QA count after waiting (more may have arrived during debounce)
    CURRENT_QA=$(count_qa_ready)

    if [ "$CURRENT_QA" -eq 0 ]; then
      # All [q] tasks vanished (auto-promoted by Big Mamma?) — nothing to check
      LAST_CHECKED_QA=0
      QA_PENDING_SINCE=0
      sleep "$POLL_INTERVAL"
      continue
    fi

    CHECKING_DESCS=$(get_recent_qa_tasks)
    write_qa_status "checking" "" "" "$CHECKING_DESCS"
    QA_PENDING_SINCE=0

    if run_checks; then
      # Promote all [q] → [x] (Spike approves!)
      lock_tasks
      qa_promoted=0
      qa_promoted=$(grep -c '^\[q\] ' "$TASK_FILE" 2>/dev/null) || true
      sedi 's/^\[q\] /[x] /' "$TASK_FILE"
      unlock_tasks

      total_done=0
      total_done=$(grep -c '^\[x\] ' "$TASK_FILE" 2>/dev/null) || true

      house_log "🐶😊 *happy bark* ALL CLEAR! Spike promotes $qa_promoted task(s) to DONE!"
      house_log "   \"That's a good cat. ...don't let it go to your head.\""
      write_qa_status "passed" "" "${total_done:-0}"
      LAST_CHECKED_QA=0
      FIX_ATTEMPT=0
    else
      FIX_ATTEMPT=$((FIX_ATTEMPT + 1))
      TRUNCATED_ERRORS=$(echo "$QA_ERRORS" | head -30)

      if [ "$FIX_ATTEMPT" -ge "$MAX_FIX_RETRIES" ]; then
        # Promote with warnings — Spike gives up
        lock_tasks
        sedi 's/^\[q\] /[x] /' "$TASK_FILE"
        unlock_tasks

        total_done=0
        total_done=$(grep -c '^\[x\] ' "$TASK_FILE" 2>/dev/null) || true

        house_log "🐶😤 *exhausted sigh* Spike tried $MAX_FIX_RETRIES times. Fine. FINE."
        house_log "   \"I'm too old for this... ship it with warnings, I don't even care anymore.\""
        write_qa_status "passed_with_warnings" "$TRUNCATED_ERRORS" "${total_done:-0}"
        LAST_CHECKED_QA=0
        FIX_ATTEMPT=0
      else
        house_log "🐶🦴 Spike GROWLS! QA FAILED (attempt $FIX_ATTEMPT/$MAX_FIX_RETRIES)!"
        house_log "   \"Listen here, Tom. You FIX this, or I fix YOU.\""
        write_qa_status "failed" "$TRUNCATED_ERRORS"
        inject_fix_task "$TRUNCATED_ERRORS"
        # Don't reset LAST_CHECKED_QA — will re-check when fix completes
        # (fix task will become [q], bumping count above LAST_CHECKED_QA)
        LAST_CHECKED_QA=$CURRENT_QA
      fi
    fi
  fi

  sleep "$POLL_INTERVAL"
done
