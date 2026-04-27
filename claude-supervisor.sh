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
source "$SCRIPT_DIR/lib/house-dispatch.sh"

# ─── Supervisor-specific config ─────────────────────────────────────────────

POLL_INTERVAL=15
LAST_DONE_COUNT=0
COMMIT_BATCH_WAIT=30       # debounce: wait this long after last change before committing
WORKER_HIBERNATING=false
GRACE_CYCLES=0             # cycles with no live worker while [!] tasks exist
GRACE_THRESHOLD=16         # 16 x 15s = 4min grace before declaring stale
ALIVE_TICKS=0              # activity logging cadence (reset when worker dies)
MAX_TASK_AGE=600           # 10 min — warn if task exceeds this
TASK_HARD_TIMEOUT=2400     # 40 min — kill worker and reset task if exceeded
PUSH_PENDING=false
PUSH_RETRIES=0
PUSH_RETRY_MAX=5           # stop retrying push after this many consecutive failures
MERGED_TO_MAIN=false
ALL_DONE_LOGGED=false
IDLE_SHUTDOWN_AFTER=1800     # 30 min idle with no tasks = graceful shutdown
IDLE_SHUTDOWN_START=0
RETRY_MAX=1
RETRIED_TASKS=""
LAST_FAILURE_TIME=0
RETRY_BACKOFF=60           # wait 60s after last failure before retrying
NOTIFICATION_FILE=".worker-done"

# Spike (QA) integration
QA_STATE=""
QA_CHECKING_TASKS=""

# Verbose log
VERBOSE_LOG="claude-supervisor-verbose.log"

# ─── Jerry (parallel workers) — initialize arrays before sourcing ──────────

P_PIDS=()
P_TASK_LINES=()
P_TASK_DESCS=()
P_ACTIVE=()
for ((_ji=0; _ji<MAX_PARALLEL; _ji++)); do
  P_PIDS+=("")
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

# ─── Tom management (Big Mamma assigns tasks directly) ──────────────────────

WORKER_VERBOSE_LOG="claude-worker-output.log"
TOM_PID=""
TOM_ACTIVE=false
TOM_TASK_LINE=""
TOM_TASK_DESC=""
TOM_TASK_STARTED=""

assign_next_to_tom() {
  local sep_line
  sep_line=$(grep -n '^_{5,}' "$TASK_FILE" 2>/dev/null | head -1 | cut -d: -f1)
  sep_line="${sep_line:-0}"
  if ! find_active_section "$TASK_FILE" "$sep_line"; then
    return 1
  fi

  # 🧠 SMART ROUTING: Tom gets heavy/conflict-prone tasks first, then light tasks
  # Priority order:
  # 1. Heavy tasks (longest duration, most complex)
  # 2. Tasks in conflict clusters (can't parallelize anyway)
  # 3. Any remaining task (FIFO)

  local -a heavy_tasks=()
  local -a conflict_tasks=()
  local -a light_tasks=()

  while IFS= read -r candidate; do
    local cand_line
    cand_line=$(echo "$candidate" | cut -d: -f1)
    [ "$cand_line" -lt "$ACTIVE_SECTION_START" ] && continue
    [ "$cand_line" -gt "$ACTIVE_SECTION_END" ] && break

    local cand_desc
    cand_desc=$(echo "$candidate" | sed 's/^[0-9]*:\[ \] //')

    # Read continuation lines
    local _cnext=$(( cand_line + 1 ))
    while [ "$_cnext" -le "$ACTIVE_SECTION_END" ]; do
      local _ccont
      _ccont=$(sed -n "${_cnext}p" "$TASK_FILE")
      if [ -z "$_ccont" ] || echo "$_ccont" | grep -qE '^\[[ xXqQ!-]\] |^#+ |^_{5,}'; then
        break
      fi
      cand_desc="${cand_desc}
${_ccont}"
      _cnext=$((_cnext + 1))
    done

    # Skip status-like lines
    if echo "$cand_desc" | grep -qiE '^(pending|done|in progress|failed|waiting)(\s|$)'; then
      continue
    fi

    # Categorize by dispatch analysis
    local complexity=$(get_task_complexity "$cand_line")
    local cluster=$(get_task_conflict_cluster "$cand_line")

    if [ "$complexity" = "heavy" ]; then
      heavy_tasks+=("$cand_line|$cand_desc")
    elif [[ "$cluster" == cluster-* ]]; then
      # Part of a conflict cluster (multiple tasks share files)
      conflict_tasks+=("$cand_line|$cand_desc")
    else
      light_tasks+=("$cand_line|$cand_desc")
    fi
  done < <(grep -n '^\[ \] ' "$TASK_FILE" 2>/dev/null || true)

  # Try categories in priority order
  local -a candidates=("${heavy_tasks[@]}" "${conflict_tasks[@]}" "${light_tasks[@]}")

  if [ ${#candidates[@]} -eq 0 ]; then
    return 1
  fi

  # Assign the first available task from priority list
  for task in "${candidates[@]}"; do
    local cand_line="${task%%|*}"
    local cand_desc="${task#*|}"

    # Claim the task
    lock_tasks
    local current
    current=$(sed -n "${cand_line}p" "$TASK_FILE" 2>/dev/null)
    if ! echo "$current" | grep -q '^\[ \] '; then
      unlock_tasks
      continue
    fi
    sedi "${cand_line}s/^\[ \] /[!] /" "$TASK_FILE"
    unlock_tasks

    # Spawn Claude for Tom (in main directory — no clone needed)
    TOM_TASK_STARTED=$(date +%s)
    local cmd="claude -p"
    [ "$AUTO_MODE" = "--auto" ] && cmd="$cmd --dangerously-skip-permissions"

    ( $cmd "$cand_desc" >> "$WORKER_VERBOSE_LOG" 2>&1; touch "$NOTIFICATION_FILE"; kill -USR1 $$ 2>/dev/null ) &
    TOM_PID=$!
    echo "$TOM_PID" > "$WORKER_PID_FILE"
    TOM_ACTIVE=true
    TOM_TASK_LINE="$cand_line"
    TOM_TASK_DESC="$cand_desc"

    # Write Tom's status file (for dashboard)
    local safe_desc="${cand_desc//$'\n'/ }"
    local route_reason="[smart: $(get_task_complexity "$cand_line")]"
    cat > "$WORKER_STATUS_FILE" <<EOF
STATE=running
WORKER_PID=$$
CLAUDE_PID=$TOM_PID
TASK_LINE=$cand_line
TASK_DESC=$safe_desc
TASK_STARTED=$TOM_TASK_STARTED
UPDATED=$(date +%s)
EOF

    house_log "${_C_BLUE}▶ TASK STARTED ─── [Tom] #${cand_line} $route_reason: ${cand_desc}${_C_RST}"
    house_log "   🐱 Tom pounced! (Claude PID $TOM_PID)"
    return 0
  done

  return 1
}

check_tom() {
  [ "$TOM_ACTIVE" = true ] || return 0

  if is_process_alive "$TOM_PID"; then
    # Hard timeout: kill if stuck too long
    if [ -n "$TOM_TASK_STARTED" ] && [ "$TOM_TASK_STARTED" -gt 0 ] 2>/dev/null; then
      local tom_age=$(( $(date +%s) - TOM_TASK_STARTED ))
      if [ "$tom_age" -ge "$TASK_HARD_TIMEOUT" ]; then
        local age_min=$((tom_age / 60))
        house_log "👩🏽🔨 ENOUGH! Tom's been stuck for ${age_min}m (limit: $((TASK_HARD_TIMEOUT / 60))m). PULLING THE PLUG!"
        kill_tree "$TOM_PID"
        sleep 2
        record_task_failure "$TOM_TASK_DESC" > /dev/null
        lock_tasks
        sedi "${TOM_TASK_LINE}s/^\[!\] /[-] /" "$TASK_FILE"
        unlock_tasks
        house_log "   👩🏽 Task #${TOM_TASK_LINE} marked FAILED. \"I gave you $((TASK_HARD_TIMEOUT / 60)) minutes, Tom. $((TASK_HARD_TIMEOUT / 60)) MINUTES!\""
        LAST_FAILURE_TIME=$(date +%s)
        TOM_PID=""
        TOM_ACTIVE=false
        TOM_TASK_LINE=""
        TOM_TASK_DESC=""
        TOM_TASK_STARTED=""
        rm -f "$WORKER_PID_FILE"
        cat > "$WORKER_STATUS_FILE" <<EOF
STATE=idle
WORKER_PID=$$
UPDATED=$(date +%s)
EOF
        return 0
      fi
    fi

    # Still running — update heartbeat for dashboard
    local safe_desc="${TOM_TASK_DESC//$'\n'/ }"
    cat > "$WORKER_STATUS_FILE" <<EOF
STATE=running
WORKER_PID=$$
CLAUDE_PID=$TOM_PID
TASK_LINE=$TOM_TASK_LINE
TASK_DESC=$safe_desc
TASK_STARTED=$TOM_TASK_STARTED
UPDATED=$(date +%s)
EOF
    return 0
  fi

  # Tom finished
  wait "$TOM_PID" 2>/dev/null
  local exit_code=$?

  lock_tasks
  if [ "$exit_code" -eq 0 ]; then
    house_log "${_C_GREEN}✓ TASK DONE ─── [Tom] #${TOM_TASK_LINE}: ${TOM_TASK_DESC}${_C_RST}"
    sedi "${TOM_TASK_LINE}s/^\[!\] /[q] /" "$TASK_FILE"
    PENDING_COMMIT=true
    LAST_CHANGE_TIME=$(date +%s)
  else
    house_log "${_C_RED}✗ TASK FAILED ─── [Tom] #${TOM_TASK_LINE} (exit $exit_code): ${TOM_TASK_DESC}${_C_RST}"
    local fail_count
    fail_count=$(record_task_failure "$TOM_TASK_DESC")
    sedi "${TOM_TASK_LINE}s/^\[!\] /[-] /" "$TASK_FILE"
    house_log "   🐱 Failure $fail_count/$TASK_FAIL_MAX for this task"
    LAST_FAILURE_TIME=$(date +%s)
  fi
  unlock_tasks

  TOM_PID=""
  TOM_ACTIVE=false
  TOM_TASK_LINE=""
  TOM_TASK_DESC=""
  rm -f "$WORKER_PID_FILE"

  cat > "$WORKER_STATUS_FILE" <<EOF
STATE=idle
WORKER_PID=$$
UPDATED=$(date +%s)
EOF
}

cleanup_tom() {
  if [ -n "$TOM_PID" ] && is_process_alive "$TOM_PID"; then
    kill_tree "$TOM_PID"
    house_log "   🐱 Tom yanked off the keyboard"
  fi
  rm -f "$WORKER_PID_FILE" "$WORKER_STATUS_FILE"
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

# ─── Fix Git safe.directory for Jerry clones (Windows compatibility) ───────
# On Windows filesystems without ownership (FAT32, exFAT, network drives),
# git clone fails with "dubious ownership" error. Add exception for .git dir.
REPO_GIT_DIR="$(pwd)/.git"
if ! git config --get-all safe.directory | grep -qF "$REPO_GIT_DIR" 2>/dev/null; then
  if git config --global --add safe.directory "$REPO_GIT_DIR" >> "$VERBOSE_LOG" 2>&1; then
    house_log "👩🏽🔧 Added git safe.directory exception for Jerry clones (Windows fix)"
  fi
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
  cleanup_tom
  cleanup_all_parallel
  rm -f "$HIBERNATE_FILE" "$NOTIFICATION_FILE" "$TASK_FAILURES_FILE"
  rm -rf "$LOCK_DIR"
  house_log "👩🏽 Big Mamma has left the building. Y'all are on your OWN now."
}
trap cleanup_supervisor EXIT
trap 'cleanup_supervisor; exit 0' INT TERM

# ─── Event-based worker notification ────────────────────────────────────────
# Workers touch .worker-done on completion. smart_sleep checks every 1s.
# USR1 signal interrupts sleep for near-instant reaction (best-effort).

trap 'true' USR1

smart_sleep() {
  local duration=$1
  for ((_ss=0; _ss<duration; _ss++)); do
    [ -f "$NOTIFICATION_FILE" ] && rm -f "$NOTIFICATION_FILE" && return 0
    sleep 1
  done
}

# Start fresh
rm -f "$HIBERNATE_FILE" "$NOTIFICATION_FILE" "$TASK_FAILURES_FILE"
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
house_log "Poll interval: ${POLL_INTERVAL}s"
house_log "Commit debounce: ${COMMIT_BATCH_WAIT}s"
house_log "Roll call: $(count_done) done, $(count_qa_ready) qa-ready, $(count_in_progress) in-progress, $(count_pending) pending, $(count_failed) failed"
house_log "\"Now let's get this house in ORDER.\""

# ─── Startup recovery: reset orphaned tasks ──────────────────────────────────
# Big Mamma starts BEFORE Tom and Spike, so ALL [!] and [q] tasks are orphaned
# from the previous session. Safe to reset everything — nobody's working yet.
_update_task_counts
STARTUP_STALE=$_COUNT_IP
STARTUP_QA=$_COUNT_QA

if [ "$STARTUP_QA" -gt 0 ]; then
  house_log "👩🏽🧹 $STARTUP_QA task(s) stuck at [q] from last session. Resetting to pending."
  sedi 's/^\[q\] /[ ] /' "$TASK_FILE"
fi

if [ "$STARTUP_STALE" -gt 0 ]; then
  house_log "👩🏽😤 $STARTUP_STALE task(s) stuck at [!] from last session! Nobody's working yet — resetting ALL."
  house_log "   \"Lord have mercy, y'all left the STOVE on!\""
  sedi 's/^\[!\] /[ ] /' "$TASK_FILE"
  house_log "   👩🏽✓ Reset $STARTUP_STALE orphaned task(s) back to pending. Fresh start."
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
      # Clear dispatch cache on section change
      clear_dispatch_cache
    fi

    # 🧠 Run pre-flight analysis when section starts (smart dispatch brain)
    if [ "$PENDING" -gt 0 ] && [ "$DISPATCH_ANALYZED_SECTION" != "$ACTIVE_SECTION_NAME" ]; then
      analyze_task_batch "$ACTIVE_SECTION_NAME" || true
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
    # Reset push retry counter — fresh work deserves a fresh attempt
    if [ "$PUSH_RETRIES" -gt "$PUSH_RETRY_MAX" ]; then
      house_log "👩🏽🔁 New work done — I'll try pushing again."
    fi
    PUSH_RETRIES=0
  fi

  # ── Retry pending pushes ──
  if [ "$PUSH_PENDING" = true ] && [ "$IN_PROGRESS" -eq 0 ]; then
    if [ "$PUSH_RETRIES" -ge "$PUSH_RETRY_MAX" ]; then
      if [ "$PUSH_RETRIES" -eq "$PUSH_RETRY_MAX" ]; then
        house_log "👩🏽✗ Push failed $PUSH_RETRY_MAX times in a row. Giving up until new work completes."
        house_log "   \"I ain't banging on a locked door all day!\""
        PUSH_RETRIES=$((PUSH_RETRIES + 1))
      fi
    else
      house_log "👩🏽🔁 Let me try that door again... (attempt $((PUSH_RETRIES + 1))/$PUSH_RETRY_MAX)"
      if push_changes; then
        PUSH_PENDING=false
        PUSH_RETRIES=0
      else
        PUSH_RETRIES=$((PUSH_RETRIES + 1))
      fi
    fi
  fi

  # ── Check on Tom (did he finish?) ──
  check_tom

  # ── Check on the Jerrys ──
  check_parallel_workers

  # ── Assign tasks to workers ──
  if [ "$PENDING" -gt 0 ]; then
    # Assign Tom first (if idle)
    if [ "$TOM_ACTIVE" != true ]; then
      assign_next_to_tom
    fi
    # Fill Jerry slots with remaining tasks
    fill_jerry_slots
  fi

  # ── Stale task detection ──
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
      smart_sleep "$POLL_INTERVAL"
      continue
    fi

    WORKER_ALIVE=false
    TASK_AGE=0

    # Check Tom (Big Mamma knows directly — no status file needed)
    if [ "$TOM_ACTIVE" = true ] && is_process_alive "$TOM_PID"; then
      WORKER_ALIVE=true
      if [ -n "$TOM_TASK_STARTED" ] && [ "$TOM_TASK_STARTED" -gt 0 ] 2>/dev/null; then
        TASK_AGE=$(( $(date +%s) - TOM_TASK_STARTED ))
      fi
    fi

    # Check Jerrys
    for ((pi=0; pi<MAX_PARALLEL; pi++)); do
      if [ "${P_ACTIVE[$pi]}" = true ] && is_process_alive "${P_PIDS[$pi]}" 2>/dev/null; then
        WORKER_ALIVE=true
        break
      fi
    done

    if [ "$WORKER_ALIVE" = true ]; then
      GRACE_CYCLES=0
      ALIVE_TICKS=$((ALIVE_TICKS + 1))

      AGE_STR="${TASK_AGE}s"
      [ "$TASK_AGE" -gt 60 ] && AGE_STR="$((TASK_AGE / 60))m$((TASK_AGE % 60))s"
      DESC_SHORT=$(short "${TOM_TASK_DESC:-unknown task}")

      # Log worker activity every ~60s + on first detection
      if [ "$ALIVE_TICKS" -eq 1 ] || [ $((ALIVE_TICKS % 4)) -eq 0 ]; then
        ALIVE_DETAIL=""
        active_p=$(count_active_parallel)
        [ "$TOM_ACTIVE" = true ] && ALIVE_DETAIL="🐱tom"
        [ "$active_p" -gt 0 ] && ALIVE_DETAIL="${ALIVE_DETAIL:+$ALIVE_DETAIL+}🐭${active_p}xjerry"
        house_log "👩🏽👀 Big Mamma's watching ($ALIVE_DETAIL, ${AGE_STR}): $DESC_SHORT"
      fi

      if [ "$TASK_AGE" -gt "$MAX_TASK_AGE" ] && [ $((ALIVE_TICKS % 8)) -eq 0 ]; then
        house_log "👩🏽⏰ Tom's been at this for ${AGE_STR}! (over $((MAX_TASK_AGE / 60))m). He's alive... just SLOW."
      fi

      smart_sleep "$POLL_INTERVAL"
      continue
    fi

    # No worker alive
    ALIVE_TICKS=0
    GRACE_CYCLES=$((GRACE_CYCLES + 1))
    if [ "$GRACE_CYCLES" -eq 1 ]; then
      house_log "👩🏽⚠ Hmm... nobody's working but $IN_PROGRESS task(s) at [!]. Grace period..."
    fi
    if [ "$GRACE_CYCLES" -ge "$GRACE_THRESHOLD" ]; then
      house_log "👩🏽😤 Workers gone for $((GRACE_CYCLES * POLL_INTERVAL))s! Recovering $IN_PROGRESS stuck task(s)..."
      recover_stale_tasks
      GRACE_CYCLES=0
    fi
    smart_sleep "$POLL_INTERVAL"
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
      smart_sleep "$POLL_INTERVAL"
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
  if [ "$PENDING" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ] && ! any_parallel_active && [ "$TOM_ACTIVE" != true ]; then
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
      smart_sleep "$POLL_INTERVAL"
      continue
    fi

    # Try retrying failed tasks (with backoff — wait RETRY_BACKOFF seconds after last failure)
    if [ "$FAILED" -gt 0 ]; then
      local since_failure=$(( NOW - LAST_FAILURE_TIME ))
      if [ "$LAST_FAILURE_TIME" -gt 0 ] && [ "$since_failure" -lt "$RETRY_BACKOFF" ]; then
        local remaining=$(( RETRY_BACKOFF - since_failure ))
        house_log "👩🏽⏳ Cooling down... ${remaining}s before retrying failed task(s). \"Let it breathe.\""
        smart_sleep "$POLL_INTERVAL"
        continue
      fi
      if retry_failed_tasks; then
        smart_sleep "$POLL_INTERVAL"
        continue
      fi
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

  smart_sleep "$POLL_INTERVAL"
done
