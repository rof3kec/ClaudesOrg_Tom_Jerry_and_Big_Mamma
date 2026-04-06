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

# ─── Source shared libraries ────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BRANCH="${1:-}"
TASK_FILE="${2:-TASKS.md}"
MERGE_MAIN="${3:-}"
AUTO_MODE="${4:-}"
MAX_PARALLEL="${5:-2}"
LOG_FILE="claude-supervisor.log"
LOG_PREFIX="[BIG MAMMA]"

source "$SCRIPT_DIR/lib/house-common.sh"
source "$SCRIPT_DIR/lib/house-tasks.sh"
source "$SCRIPT_DIR/lib/house-git.sh"

# ─── Supervisor-specific config ─────────────────────────────────────────────

POLL_INTERVAL=15
LAST_DONE_COUNT=0
COMMIT_BATCH_WAIT=30       # debounce: wait this long after last change before committing
WORKER_HIBERNATING=false
GRACE_CYCLES=0             # cycles with no live worker while [!] tasks exist
GRACE_THRESHOLD=16         # 16 x 15s = 4min grace before declaring stale
ALIVE_TICKS=0              # activity logging cadence (reset when worker dies)
MAX_TASK_AGE=600           # 10 min — warn if task exceeds this
PUSH_PENDING=false
MERGED_TO_MAIN=false
ALL_DONE_LOGGED=false
IDLE_SHUTDOWN_AFTER=1800     # 30 min idle with no tasks = graceful shutdown
IDLE_SHUTDOWN_START=0
RETRY_MAX=1
RETRIED_TASKS=""

# Spike (QA) integration
QA_STATE=""
QA_CHECKING_TASKS=""

# Verbose log
VERBOSE_LOG="claude-supervisor-verbose.log"

# ─── Jerry (parallel workers) — initialize arrays before sourcing ──────────

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

source "$SCRIPT_DIR/lib/house-jerry.sh"

# ─── Tom's status ───────────────────────────────────────────────────────────

read_worker_status() {
  WSTAT_STATE="" WSTAT_WORKER_PID="" WSTAT_CLAUDE_PID=""
  WSTAT_TASK_LINE="" WSTAT_TASK_DESC="" WSTAT_TASK_STARTED="" WSTAT_UPDATED=""
  [ -f "$WORKER_STATUS_FILE" ] || return 1
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
  done < "$WORKER_STATUS_FILE"
  return 0
}

# ─── Spike's & Sdike's status ─────────────────────────────────────────────────

read_qa_status() {
  QA_STATE="idle"
  QA_VALIDATED_DONE=""
  QA_CHECKING_TASKS=""

  # Read Spike's status (primary QA)
  if [ -f "$QA_STATUS_FILE" ]; then
    QA_STATE=$(grep '^STATE=' "$QA_STATUS_FILE" 2>/dev/null | cut -d= -f2)
    QA_VALIDATED_DONE=$(grep '^VALIDATED_DONE=' "$QA_STATUS_FILE" 2>/dev/null | cut -d= -f2)
    QA_CHECKING_TASKS=$(grep '^CHECKING_TASKS=' "$QA_STATUS_FILE" 2>/dev/null | cut -d= -f2-)
    [ -n "$QA_STATE" ] || QA_STATE="idle"
  fi

  # If Spike hasn't passed, check if Sdike has (either brother's approval counts)
  if [ "$QA_STATE" != "passed" ] && [ "$QA_STATE" != "passed_with_warnings" ] && [ -f "$SDIKE_STATUS_FILE" ]; then
    local sdike_state
    sdike_state=$(grep '^STATE=' "$SDIKE_STATUS_FILE" 2>/dev/null | cut -d= -f2)
    if [ "$sdike_state" = "passed" ] || [ "$sdike_state" = "passed_with_warnings" ]; then
      QA_STATE="$sdike_state"
      QA_VALIDATED_DONE=$(grep '^VALIDATED_DONE=' "$SDIKE_STATUS_FILE" 2>/dev/null | cut -d= -f2)
      QA_CHECKING_TASKS=$(grep '^CHECKING_TASKS=' "$SDIKE_STATUS_FILE" 2>/dev/null | cut -d= -f2-)
    fi
  fi

  [ -f "$QA_STATUS_FILE" ] || [ -f "$SDIKE_STATUS_FILE" ] || return 1
  return 0
}

# ─── Claude liveness check ──────────────────────────────────────────────────

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

# ─── Pre-flight checks ──────────────────────────────────────────────────────

if ! command -v git &>/dev/null; then
  house_die "git not found in PATH"
fi

if [ ! -d .git ]; then
  house_die "Not a git repository. Run from repo root."
fi

if [ ! -f "$TASK_FILE" ]; then
  house_die "Task file '$TASK_FILE' not found."
fi

# Detect branch
if [ -z "$BRANCH" ]; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  if [ -z "$BRANCH" ]; then
    house_die "Could not detect current branch. Pass it as argument."
  fi
fi

if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
  house_die "I will NOT push to '$BRANCH'! Use a dev branch, child. Big Mamma didn't raise no fool."
fi

if ! git remote get-url origin &>/dev/null; then
  house_die "No 'origin' remote configured."
fi

# ─── Read CLAUDE.md and Mamma Instructions ─────────────────────────────────

CLAUDE_MD_CONTENT=""
if [ -f "CLAUDE.md" ]; then
  CLAUDE_MD_CONTENT=$(cat "CLAUDE.md" 2>/dev/null | head -200)
  house_log "👩🏽📖 Big Mamma read the CLAUDE.md. She knows what's what."
else
  house_log "👩🏽 No CLAUDE.md found. Big Mamma's flying blind — but she's BEEN doing this."
fi

MAMMA_INSTRUCTIONS=""
if [ -f "$TASK_FILE" ]; then
  MAMMA_INSTRUCTIONS=$(awk '
    /^## Mamma Instructions/{ found=1; next }
    found && /^_{5,}|^## |^# /{ exit }
    found { print }
  ' "$TASK_FILE" 2>/dev/null | sed '/^<!--/,/-->$/d; /^$/d' | head -100)
  if [ -n "$MAMMA_INSTRUCTIONS" ]; then
    house_log "👩🏽📋 Mamma Instructions loaded. Big Mamma knows the PLAN."
  fi
fi

# ─── State ───────────────────────────────────────────────────────────────────

LAST_DONE_COUNT=$(count_done)
LAST_QA_COUNT=$(count_qa_ready)
LAST_CHANGE_TIME=0
PENDING_COMMIT=false
CURRENT_ACTIVE_SECTION=""

# Cleanup on exit
cleanup_supervisor() {
  cleanup_all_parallel
  rm -f "$HIBERNATE_FILE"
  rm -rf "$LOCK_DIR"
  house_log "👩🏽 Big Mamma has left the building. Y'all are on your OWN now."
}
trap cleanup_supervisor EXIT
trap 'cleanup_supervisor; exit 0' INT TERM

# Start fresh
rm -f "$HIBERNATE_FILE"
rm -rf "$LOCK_DIR"
# Prune stale worktrees from previous runs
git worktree prune >> "$VERBOSE_LOG" 2>&1 || true

house_log "╔═══════════════════════════════════════════════════════╗"
house_log "║  👩🏽 Big Mamma's in the HOUSE! Everybody BEHAVE!       ║"
house_log "╚═══════════════════════════════════════════════════════╝"
house_log "Branch: $BRANCH"
house_log "Task file: $TASK_FILE"
house_log "Auto mode: ${AUTO_MODE:-off}"
house_log "CLAUDE.md: $([ -n "$CLAUDE_MD_CONTENT" ] && echo 'loaded ✓' || echo 'not found')"
house_log "Mamma Instructions: $([ -n "$MAMMA_INSTRUCTIONS" ] && echo 'loaded ✓' || echo 'none')"
house_log "Jerry slots: $MAX_PARALLEL"
# Log Jerry specializations
if [ -f "$JERRY_SPECS_FILE" ]; then
  for ((_si=0; _si<MAX_PARALLEL; _si++)); do
    _spec=$(read_jerry_spec "$_si")
    [ "$_spec" != "fullstack" ] && house_log "   Jerry #$_si: $_spec"
  done
fi
house_log "Poll interval: ${POLL_INTERVAL}s"
house_log "Commit debounce: ${COMMIT_BATCH_WAIT}s"
house_log "Roll call: $(count_done) done, $(count_qa_ready) qa-ready, $(count_in_progress) in-progress, $(count_pending) pending, $(count_failed) failed"
house_log "\"Now let's get this house in ORDER.\""

# ─── Startup recovery: reset orphaned tasks ──────────────────────────────────
# Tom starts ~3s before the supervisor, so he may already have a live [!] task.
# Don't blindly reset it — check if Tom is alive first.
# Also reset stale [q] tasks from previous sessions — the work may have been
# merged, but Spike should re-validate from scratch on a fresh start.
_update_task_counts
STARTUP_STALE=$_COUNT_IP
STARTUP_QA=$_COUNT_QA

# Reset stale [q] tasks — previous session's Spike didn't finish validating
if [ "$STARTUP_QA" -gt 0 ]; then
  house_log "👩🏽🧹 $STARTUP_QA task(s) stuck at [q] from last session. Resetting to pending."
  sedi 's/^\[q\] /[ ] /' "$TASK_FILE"
fi

if [ "$STARTUP_STALE" -gt 0 ]; then
  _tom_alive=false
  _tom_task_line=""
  if is_claude_alive; then
    _tom_alive=true
  fi
  if read_worker_status 2>/dev/null && [ "$WSTAT_STATE" = "running" ] && \
     [ -n "$WSTAT_WORKER_PID" ] && is_process_alive "$WSTAT_WORKER_PID"; then
    _tom_alive=true
    _tom_task_line="$WSTAT_TASK_LINE"
  fi

  if [ "$_tom_alive" = true ] && [ -n "$_tom_task_line" ]; then
    # Tom is already working — keep his task, reset any other stale [!] tasks
    _stale_others=$(( STARTUP_STALE - 1 ))
    if [ "$_stale_others" -gt 0 ]; then
      house_log "👩🏽😤 Tom's on task #$_tom_task_line, but $_stale_others other [!] task(s) are orphaned. Resetting those."
      awk -v tl="$_tom_task_line" 'NR==tl{print; next} /^\[!\] /{sub(/^\[!\] /,"[ ] ")} {print}' \
        "$TASK_FILE" > "$TASK_FILE.tmp" && mv "$TASK_FILE.tmp" "$TASK_FILE"
    else
      house_log "👩🏽 Tom's already chasing task #$_tom_task_line. No orphans. Good boy."
    fi
  elif [ "$_tom_alive" = true ]; then
    house_log "👩🏽 Tom's alive but task line unknown. Leaving [!] tasks alone to be safe."
  else
    house_log "👩🏽😤 $STARTUP_STALE task(s) stuck at [!] from last session! Nobody's working yet — resetting ALL."
    house_log "   \"Lord have mercy, y'all left the STOVE on!\""
    sedi 's/^\[!\] /[ ] /' "$TASK_FILE"
    house_log "   👩🏽✓ Reset $STARTUP_STALE orphaned task(s) back to pending. Fresh start."
  fi
fi
LAST_DONE_COUNT=$(count_done)

# ─── Main loop ───────────────────────────────────────────────────────────────

while true; do
  # Single pass through TASKS.md for all counts
  _update_task_counts
  CURRENT_DONE=$_COUNT_DONE
  IN_PROGRESS=$_COUNT_IP
  PENDING=$_COUNT_PENDING
  FAILED=$_COUNT_FAILED
  QA_READY=$_COUNT_QA
  NOW=$(date +%s)

  # Track active section transitions
  _sep=$(grep -n '^_{5,}' "$TASK_FILE" 2>/dev/null | head -1 | cut -d: -f1)
  _sep="${_sep:-0}"
  if find_active_section "$TASK_FILE" "$_sep"; then
    if [ "$ACTIVE_SECTION_NAME" != "$CURRENT_ACTIVE_SECTION" ]; then
      if [ -n "$CURRENT_ACTIVE_SECTION" ] && [ "$CURRENT_ACTIVE_SECTION" != "(all tasks)" ]; then
        house_log "👩🏽✅ Section complete: $CURRENT_ACTIVE_SECTION"
      fi
      CURRENT_ACTIVE_SECTION="$ACTIVE_SECTION_NAME"
      if [ "$ACTIVE_SECTION_NAME" != "(all tasks)" ]; then
        house_log "👩🏽📋 Now working on: $ACTIVE_SECTION_NAME"
      fi
    fi
  fi

  # Detect tasks newly ready for QA (worker finished → [q])
  if [ "$QA_READY" -gt "$LAST_QA_COUNT" ]; then
    NEW_QA=$((QA_READY - LAST_QA_COUNT))
    house_log "👩🏽😊 Well well! $NEW_QA task(s) ready for Spike! (total: $QA_READY). Now let's see if they PASS."
    LAST_QA_COUNT=$QA_READY
    LAST_CHANGE_TIME=$NOW
    PENDING_COMMIT=true
  elif [ "$QA_READY" -lt "$LAST_QA_COUNT" ]; then
    LAST_QA_COUNT=$QA_READY  # Spike promoted some — sync counter
  fi

  # Detect newly validated tasks (Spike promoted [q] → [x])
  if [ "$CURRENT_DONE" -gt "$LAST_DONE_COUNT" ]; then
    NEW_VALIDATED=$((CURRENT_DONE - LAST_DONE_COUNT))
    house_log "👩🏽😊 Spike APPROVED $NEW_VALIDATED task(s)! (total: $CURRENT_DONE). That's what I like to see!"
    LAST_DONE_COUNT=$CURRENT_DONE
    LAST_CHANGE_TIME=$NOW
    PENDING_COMMIT=true
  fi

  # ── Retry pending pushes ──
  if [ "$PUSH_PENDING" = true ] && [ "$IN_PROGRESS" -eq 0 ]; then
    house_log "👩🏽🔁 Let me try that door again..."
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
      house_log "👩🏽🧮 HOLD UP! $IN_PROGRESS tasks at [!] but I only got $MAX_POSSIBLE workers (1 Tom + $MAX_PARALLEL Jerry)!"
      house_log "   \"I can COUNT, children! That math don't ADD UP!\" Recovering stale tasks NOW."
      recover_stale_tasks
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
        house_log "👩🏽👀 Big Mamma's watching ($ALIVE_DETAIL, ${AGE_STR}): $DESC_SHORT"
      fi

      if [ "$TASK_AGE" -gt "$MAX_TASK_AGE" ] && [ $((ALIVE_TICKS % 8)) -eq 0 ]; then
        house_log "👩🏽⏰ Tom's been at this for ${AGE_STR}! (over $((MAX_TASK_AGE / 60))m). He's alive... just SLOW."
      fi

      sleep "$POLL_INTERVAL"
      continue
    fi

    # Neither Tom nor Claude is alive
    ALIVE_TICKS=0

    if [ -f "$HIBERNATE_FILE" ]; then
      house_log "👩🏽😤 Tom's HIBERNATING but $IN_PROGRESS task(s) stuck at [!]?! Oh HELL no."
      recover_stale_tasks
      wake_worker
      GRACE_CYCLES=0
      sleep "$POLL_INTERVAL"
      continue
    fi

    # Dead worker — grace period before recovery
    GRACE_CYCLES=$((GRACE_CYCLES + 1))
    if [ "$GRACE_CYCLES" -eq 1 ]; then
      house_log "👩🏽⚠ Hmm... I don't hear Tom OR Jerry. Grace period: ${GRACE_THRESHOLD} cycles (~$((GRACE_THRESHOLD * POLL_INTERVAL))s)..."
    fi
    if [ "$GRACE_CYCLES" -ge "$GRACE_THRESHOLD" ]; then
      house_log "👩🏽😤 THOMAS! You been GONE for $((GRACE_CYCLES * POLL_INTERVAL))s! Recovering $IN_PROGRESS stuck task(s)..."
      house_log "   \"I swear, that cat is gonna give me GRAY HAIR!\""
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
      house_log "👩🏽⏳ Hold your horses... ${REMAINING}s until commit (letting things settle)"
      sleep "$POLL_INTERVAL"
      continue
    fi

    # Commit changes locally (always — push is Spike-gated)
    if has_changes; then
      house_log "👩🏽📦 Packaging up the work..."
      git add -A 2>/dev/null

      DONE_SUMMARY=$(get_recent_done_tasks 5)
      COMMIT_MSG="auto: completed tasks (supervisor)

Tasks done:
$DONE_SUMMARY

Status: $CURRENT_DONE done, $QA_READY qa-ready, $PENDING pending, $FAILED failed"

      if git commit -m "$COMMIT_MSG" >> "$VERBOSE_LOG" 2>&1; then
        house_log "👩🏽✓ Committed locally. Mm-hmm."
      else
        house_log "👩🏽 Nothing to commit. Moving on."
      fi
    fi

    # Push is gated on Spike's approval
    if read_qa_status; then
      case "$QA_STATE" in
        passed|passed_with_warnings)
          if [ "$QA_STATE" = "passed_with_warnings" ]; then
            house_log "👩🏽⚠ Spike passed it with WARNINGS. Good enough. Pushing."
          else
            house_log "👩🏽😊 Spike says it's CLEAN! That's what I like to hear! Pushing..."
          fi
          push_changes
          PENDING_COMMIT=false
          cleanup_done_tasks
          ;;
        checking)
          if [ -n "$QA_CHECKING_TASKS" ]; then
            house_log "👩🏽⏳ Spike's still sniffing around... hold your horses, Tom. ${_C_YELLOW}[QA: ${QA_CHECKING_TASKS}]${_C_RST}"
          else
            house_log "👩🏽⏳ Spike's still sniffing around... hold your horses, Tom."
          fi
          ;;
        failed)
          house_log "👩🏽😤 Spike found a MESS! Tom, you better FIX that!"
          house_log "   (Spike will inject a fix task. We wait.)"
          ;;
        idle)
          house_log "👩🏽⏳ Waiting for Spike to start his rounds..."
          ;;
      esac
    else
      # No Spike on duty — push without QA gate
      house_log "👩🏽⚠ Spike's not around! Pushing without QA. Lord help us."
      push_changes
      PENDING_COMMIT=false
    fi
  fi

  # ── All tasks done? ──
  if [ "$PENDING" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ] && ! any_parallel_active; then
    hibernate_worker

    # Wait for Spike to validate [q] tasks before declaring done
    if [ "$QA_READY" -gt 0 ]; then
      if read_qa_status; then
        if [ "$ALL_DONE_LOGGED" = false ]; then
          house_log "👩🏽⏳ $QA_READY task(s) awaiting Spike's inspection. Hold tight, y'all."
          ALL_DONE_LOGGED=true
        fi
      else
        # Spike's not around — auto-promote [q] → [x]
        house_log "👩🏽⚠ Spike's NOT around! Auto-approving $QA_READY task(s). Lord help us."
        lock_tasks
        sedi 's/^\[q\] /[x] /' "$TASK_FILE"
        unlock_tasks
        LAST_QA_COUNT=0
        ALL_DONE_LOGGED=false
      fi
      sleep "$POLL_INTERVAL"
      continue
    fi

    # Try retrying failed tasks before declaring done
    if [ "$FAILED" -gt 0 ] && retry_failed_tasks; then
      sleep "$POLL_INTERVAL"
      continue
    fi

    # Log "all done" only ONCE to prevent spam
    if [ "$ALL_DONE_LOGGED" = false ]; then
      if [ "$FAILED" -gt 0 ]; then
        house_log "👩🏽 All tasks processed. $CURRENT_DONE done, $FAILED FAILED (retries exhausted). Tom is resting."
        if [ "$MERGE_MAIN" = "--main" ] && [ "$MERGED_TO_MAIN" = false ]; then
          house_log "👩🏽✗ NOT merging to main — $FAILED task(s) failed. Fix them FIRST, Thomas."
        fi
      else
        house_log "👩🏽🎉 HALLELUJAH! ALL $CURRENT_DONE tasks are DONE! Big Mamma is PROUD!"
        house_log "   \"Now THAT'S how you run a house!\""
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
        house_log "👩🏽💤 No new tasks for $((idle_elapsed / 60)) minutes. Big Mamma's closing up shop."
        house_log "   \"The house runs itself now. Good night, y'all.\""
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
