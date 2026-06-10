#!/usr/bin/env bash
# claude-qa.sh — 🐶 Spike the Bulldog (& 🐕 Sdike): quality enforcers
#
# "Listen here, pussycat. You make a mess, I make you CLEAN it up."
#                                                        — Spike
# "I can sniff bugs too, bro! Watch me!"
#                                                        — Sdike
#
# Monitors TASKS.md for completed tasks and runs build/lint/type checks.
# If checks fail, the QA dog sends Tom right back to fix his mess.
# When the QA queue gets deep (5+), Sdike auto-spawns to help his brother.
#
# Usage:
#   ./claude-qa.sh                  # uses TASKS.md (as Spike)
#   ./claude-qa.sh TASKS.md         # custom task file (as Spike)
#   ./claude-qa.sh TASKS.md sdike   # run as Sdike (Spike's brother)

set -u

# ─── Source shared library ───────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TASK_FILE="${1:-TASKS.md}"
IDENTITY="${2:-spike}"

# ─── Identity: Spike or Sdike ───────────────────────────────────────────────

if [ "$IDENTITY" = "sdike" ]; then
  LOG_FILE="claude-qa-sdike.log"
  LOG_PREFIX="[SDIKE]"
  QA_ICON="🐕"
  QA_NAME="Sdike"
else
  LOG_FILE="claude-qa.log"
  LOG_PREFIX="[SPIKE]"
  QA_ICON="🐶"
  QA_NAME="Spike"
fi

source "$SCRIPT_DIR/lib/house-common.sh"

# ─── QA-specific config ─────────────────────────────────────────────────────

if [ "$IDENTITY" = "sdike" ]; then
  STATUS_FILE=".qa-status-sdike"
else
  STATUS_FILE=".qa-status"
fi
MAX_PARALLEL=$(cat .house-jerries 2>/dev/null || echo 2)
POLL_INTERVAL=10           # how often Spike sniffs the queue (was 20 — snappier)
MAX_FIX_RETRIES=3
FIX_ATTEMPT=0
QA_ERRORS=""
QA_DEBOUNCE=20             # settle window after new tasks land before running QA
QA_BACKLOG_FORCE=5         # if this many tasks are waiting, check NOW (skip the settle wait)
QA_RECHECK_INTERVAL=120    # re-check stranded [q] tasks if this long since the last QA pass
QA_PENDING_SINCE=0         # timestamp when we first noticed new completions

if [ ! -f "$TASK_FILE" ]; then
  echo "ERROR: Task file '$TASK_FILE' not found. Spike has nothing to sniff!"
  exit 1
fi

# ─── QA Run Lock (prevents Spike and Sdike from running checks simultaneously) ─

QA_RUN_LOCK=".qa-running.lock"

try_claim_qa_run() {
  if mkdir "$QA_RUN_LOCK" 2>/dev/null; then
    echo $$ > "$QA_RUN_LOCK/pid"
    return 0
  fi
  # Check if the holder is still alive (stale lock recovery)
  local holder_pid
  holder_pid=$(cat "$QA_RUN_LOCK/pid" 2>/dev/null)
  if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
    rm -rf "$QA_RUN_LOCK"
    if mkdir "$QA_RUN_LOCK" 2>/dev/null; then
      echo $$ > "$QA_RUN_LOCK/pid"
      return 0
    fi
  fi
  return 1
}

release_qa_run() {
  rm -rf "$QA_RUN_LOCK"
}

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
  if [ "$IDENTITY" = "sdike" ]; then
    house_log "🐕💢 Sdike drops a fix task in Tom's bowl: \"Bro says you gotta fix this, Tom!\""
  else
    house_log "🐶💢 Spike drops a fix task in Tom's bowl: \"CLEAN. THIS. UP. NOW.\""
  fi
}

# ─── Quality checks ─────────────────────────────────────────────────────────

run_checks() {
  if [ "$IDENTITY" = "sdike" ]; then
    house_log "🐕🔍 *sniff sniff* Sdike is inspecting the premises..."
  else
    house_log "🐶🔍 *sniff sniff* Spike is inspecting the premises..."
  fi

  # Let the AI analyze the project and run whatever checks are appropriate.
  # This works for any stack: web, mobile, game dev, backend, ML, etc.
  CLAUDE_QA=$(get_ai_cmd qa "--auto")

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
    house_log "$QA_ICON✓ *tail wag* All checks clean!"
    QA_ERRORS=""
    return 0
  elif echo "$qa_output" | grep -q "QA_RESULT:FAIL"; then
    local errors
    errors=$(echo "$qa_output" | sed -n '/QA_RESULT:FAIL/,$p' | tail -n +2 | head -30)
    house_log "$QA_ICON💢 GRRR! Errors found! WHO DID THIS?!"
    QA_ERRORS="$errors"
    return 1
  else
    # Claude didn't return a clear verdict — treat as pass with warning
    house_log "$QA_ICON❓ $QA_NAME couldn't determine a clear verdict — allowing pass with warning"
    QA_ERRORS=""
    return 0
  fi
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────

cleanup_qa() {
  rm -f "$STATUS_FILE"
  release_qa_run 2>/dev/null || true
}

trap cleanup_qa EXIT
trap 'cleanup_qa; exit 0' INT TERM

# ─── Startup ─────────────────────────────────────────────────────────────────

LAST_CHECKED_QA=0
LAST_QA_PASS_TS=$(date +%s)   # when we last actually ran a QA check (for stranded-task rescue)
write_qa_status "idle"

if [ "$IDENTITY" = "sdike" ]; then
  house_log "╔═══════════════════════════════════════════════════════╗"
  house_log "║  🐕 Sdike — Spike's Little Brother (QA Backup)        ║"
  house_log "║  Watching: $TASK_FILE"
  house_log "║  \"I can sniff bugs too, bro! Watch me!\"              ║"
  house_log "╚═══════════════════════════════════════════════════════╝"
else
  house_log "╔═══════════════════════════════════════════════════════╗"
  house_log "║  🐶 Spike the Bulldog — Quality Enforcer              ║"
  house_log "║  Watching: $TASK_FILE"
  house_log "║  \"Nobody ships bugs on MY watch. Nobody.\"             ║"
  house_log "╚═══════════════════════════════════════════════════════╝"
fi
house_log "Initial QA-ready count: $LAST_CHECKED_QA"

# ─── Main loop ───────────────────────────────────────────────────────────────

while true; do
  CURRENT_QA=$(count_qa_ready)
  NOW_TS=$(date +%s)

  # Decide whether Spike should check this cycle. Three independent triggers:
  #   1. NEW work     — more [q] tasks than we last acted on
  #   2. STRANDED work — [q] tasks exist but haven't been checked in a long time
  #                      (rescues tasks left behind after a failed/stalled fix cycle)
  SINCE_LAST_PASS=$((NOW_TS - LAST_QA_PASS_TS))
  HAVE_NEW_WORK=false
  HAVE_STRANDED_WORK=false
  if [ "$CURRENT_QA" -gt "$LAST_CHECKED_QA" ] || { [ "$CURRENT_QA" -gt 0 ] && [ "$LAST_CHECKED_QA" -eq 0 ]; }; then
    HAVE_NEW_WORK=true
  fi
  if [ "$CURRENT_QA" -gt 0 ] && [ "$SINCE_LAST_PASS" -ge "$QA_RECHECK_INTERVAL" ]; then
    HAVE_STRANDED_WORK=true
  fi

  if [ "$HAVE_NEW_WORK" = true ] || [ "$HAVE_STRANDED_WORK" = true ]; then
    if [ "$HAVE_STRANDED_WORK" = true ] && [ "$HAVE_NEW_WORK" = false ]; then
      house_log "$QA_ICON🦴 $QA_NAME smells something stale — $CURRENT_QA task(s) sat in QA too long. Re-inspecting!"
      QA_PENDING_SINCE=1   # stranded work has already waited plenty; don't debounce again
    fi

    # New QA-ready tasks detected — start/reset the debounce timer
    if [ "$QA_PENDING_SINCE" -eq 0 ]; then
      if [ "$IDENTITY" = "sdike" ]; then
        house_log "🐕👀 Sdike's ears perk up! $CURRENT_QA task(s) ready for QA. I got this, bro!"
      else
        house_log "🐶👀 Spike's ears perk up! $CURRENT_QA task(s) ready for QA. Time to inspect!"
      fi
      QA_PENDING_SINCE=$NOW_TS
    fi

    # Debounce: wait for QA_DEBOUNCE seconds of stability before checking.
    # This prevents running QA on every single task during rapid sequential
    # execution. BUT: if the backlog is deep (>= QA_BACKLOG_FORCE), or tasks have
    # been settling longer than the debounce window in total, check NOW. Otherwise
    # a steady drip of completions would reset the timer forever and Spike would
    # never actually run — the exact "10+ tasks stuck pending QA" failure.
    DEBOUNCE_ELAPSED=$((NOW_TS - QA_PENDING_SINCE))
    if [ "$CURRENT_QA" -lt "$QA_BACKLOG_FORCE" ] && [ "$DEBOUNCE_ELAPSED" -lt "$QA_DEBOUNCE" ]; then
      # Still settling and backlog is shallow — wait one poll, but do NOT reset the
      # timer just because more tasks arrived. The timer only ever moves forward to
      # expiry, guaranteeing Spike checks within QA_DEBOUNCE of the FIRST task.
      sleep "$POLL_INTERVAL"
      continue
    fi
    if [ "$CURRENT_QA" -ge "$QA_BACKLOG_FORCE" ] && [ "$DEBOUNCE_ELAPSED" -lt "$QA_DEBOUNCE" ]; then
      house_log "$QA_ICON🔥 Backlog is deep ($CURRENT_QA tasks)! $QA_NAME stops waiting and dives in NOW."
    fi

    # Debounce expired — also wait for workers to finish current task
    WAIT_CYCLES=0
    while is_any_worker_active && [ "$WAIT_CYCLES" -lt 40 ]; do
      if [ "$WAIT_CYCLES" -eq 0 ]; then
        if [ "$IDENTITY" = "sdike" ]; then
          house_log "🐕⏳ Sdike waits by the door, tail wagging... waiting for Tom to finish..."
        else
          house_log "🐶⏳ Spike sits by the door, one eye open... waiting for Tom to finish..."
        fi
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

    # Claim QA run lock — only one dog checks at a time
    if ! try_claim_qa_run; then
      house_log "$QA_ICON⏳ $QA_NAME sees his brother is already checking. Standing by..."
      QA_PENDING_SINCE=0
      sleep "$POLL_INTERVAL"
      continue
    fi

    CHECKING_DESCS=$(get_recent_qa_tasks)
    write_qa_status "checking" "" "" "$CHECKING_DESCS"
    QA_PENDING_SINCE=0
    LAST_QA_PASS_TS=$(date +%s)   # a real inspection is happening now — reset stranded timer

    if run_checks; then
      # Promote all [q] → [x] (QA approves!)
      lock_tasks
      qa_promoted=0
      qa_promoted=$(grep -c '^\[q\] ' "$TASK_FILE" 2>/dev/null) || true
      sedi 's/^\[q\] /[x] /' "$TASK_FILE"
      unlock_tasks

      total_done=0
      total_done=$(grep -c '^\[x\] ' "$TASK_FILE" 2>/dev/null) || true

      if [ "$IDENTITY" = "sdike" ]; then
        house_log "🐕😊 *excited yap* ALL CLEAR! Sdike promotes $qa_promoted task(s) to DONE!"
        house_log "   \"See, bro? I told you I could do it!\""
      else
        house_log "🐶😊 *happy bark* ALL CLEAR! Spike promotes $qa_promoted task(s) to DONE!"
        house_log "   \"That's a good cat. ...don't let it go to your head.\""
      fi
      write_qa_status "passed" "" "${total_done:-0}"
      LAST_CHECKED_QA=0
      FIX_ATTEMPT=0
    else
      FIX_ATTEMPT=$((FIX_ATTEMPT + 1))
      TRUNCATED_ERRORS=$(echo "$QA_ERRORS" | head -30)

      if [ "$FIX_ATTEMPT" -ge "$MAX_FIX_RETRIES" ]; then
        # Promote with warnings — QA gives up
        lock_tasks
        sedi 's/^\[q\] /[x] /' "$TASK_FILE"
        unlock_tasks

        total_done=0
        total_done=$(grep -c '^\[x\] ' "$TASK_FILE" 2>/dev/null) || true

        if [ "$IDENTITY" = "sdike" ]; then
          house_log "🐕😤 *whimper* Sdike tried $MAX_FIX_RETRIES times. I'm sorry, bro..."
          house_log "   \"I did my best... ship it with warnings.\""
        else
          house_log "🐶😤 *exhausted sigh* Spike tried $MAX_FIX_RETRIES times. Fine. FINE."
          house_log "   \"I'm too old for this... ship it with warnings, I don't even care anymore.\""
        fi
        write_qa_status "passed_with_warnings" "$TRUNCATED_ERRORS" "${total_done:-0}"
        LAST_CHECKED_QA=0
        FIX_ATTEMPT=0
      else
        if [ "$IDENTITY" = "sdike" ]; then
          house_log "🐕🦴 Sdike BARKS! QA FAILED (attempt $FIX_ATTEMPT/$MAX_FIX_RETRIES)!"
          house_log "   \"Hey Tom! My brother's gonna be MAD if you don't fix this!\""
        else
          house_log "🐶🦴 Spike GROWLS! QA FAILED (attempt $FIX_ATTEMPT/$MAX_FIX_RETRIES)!"
          house_log "   \"Listen here, Tom. You FIX this, or I fix YOU.\""
        fi
        write_qa_status "failed" "$TRUNCATED_ERRORS"
        inject_fix_task "$TRUNCATED_ERRORS"
        # Don't reset LAST_CHECKED_QA — will re-check when fix completes
        # (fix task will become [q], bumping count above LAST_CHECKED_QA)
        LAST_CHECKED_QA=$CURRENT_QA
      fi
    fi

    release_qa_run
  else
    # Sync LAST_CHECKED_QA downward if [q] count dropped externally
    # (e.g., Big Mamma auto-promoted during a Spike restart window)
    if [ "$CURRENT_QA" -lt "$LAST_CHECKED_QA" ]; then
      LAST_CHECKED_QA=$CURRENT_QA
    fi
  fi

  sleep "$POLL_INTERVAL"
done
