#!/usr/bin/env bash
# claude-start.sh — 🏠 Opens the House: Tom, Jerry, Big Mamma & Spike
#
# "Another day, another dollar. Let's get this house in ORDER."
#                                                — Big Mamma
#
# Usage:
#   ./claude-start.sh                                  # default: CWD, TASKS.md
#   ./claude-start.sh --auto                           # skip permission prompts
#   ./claude-start.sh --location D:/Projects/MyApp     # work in a different directory
#   ./claude-start.sh --auto --location D:/Projects/MyApp --branch feat --main
#
# The scripts can live anywhere (e.g., D:/ root). Use --location to point
# at the project directory where TASKS.md and work happen.
#
# Ctrl+C = Big Mamma says "EVERYBODY OUT!"

set -u

# ─── Error helper (shows message + pauses so Windows terminals don't vanish) ─

fail() {
  echo "$@" >&2
  # If running in an interactive terminal, pause so the user can read the error
  if [ -t 0 ]; then
    echo ""
    read -rp "Press Enter to close..."
  fi
  exit 1
}

# ─── Resolve script directory (where this script and siblings live) ──────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Defaults ────────────────────────────────────────────────────────────────

TASK_FILE="TASKS.md"
BRANCH=""
AUTO_MODE="--auto"
MERGE_MAIN=""
LOCATION=""
LOCK_FILE=".claude-start.lock"

# ─── Parse args ──────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto)          AUTO_MODE="--auto"; shift ;;
    --branch|-b)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        fail "ERROR: --branch requires a value.  Usage: --branch <name>"
      fi
      BRANCH="$2"; shift 2 ;;
    --tasks|-t)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        fail "ERROR: --tasks requires a value.  Usage: --tasks <file>"
      fi
      TASK_FILE="$2"; shift 2 ;;
    --main)          MERGE_MAIN="--main"; shift ;;
    --location|-l)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        fail "ERROR: --location requires a value.  Usage: --location <path>"
      fi
      LOCATION="$2"; shift 2 ;;
    *)               fail "Unknown arg: $1" ;;
  esac
done

# ─── Change to project location ─────────────────────────────────────────────

if [ -n "$LOCATION" ]; then
  # Normalize Windows paths (D:// -> D:/, backslashes -> forward)
  LOCATION=$(echo "$LOCATION" | sed 's|\\|/|g; s|//|/|g')

  if [ ! -d "$LOCATION" ]; then
    fail "ERROR: Location '$LOCATION' does not exist."
  fi

  cd "$LOCATION" || fail "ERROR: Cannot cd to '$LOCATION'"
  echo "[claude-start] Working directory: $(pwd)"
fi

# ─── Pre-flight ──────────────────────────────────────────────────────────────

# Scripts must exist in SCRIPT_DIR
for script in claude-worker.sh claude-supervisor.sh claude-qa.sh; do
  if [ ! -f "$SCRIPT_DIR/$script" ]; then
    fail "ERROR: $script not found in $SCRIPT_DIR"
  fi
done

# Must be inside a git repo
if [ ! -d .git ]; then
  fail "ERROR: $(pwd) is not a git repository. Initialize one with: git init"
fi

# Create TASKS.md if it doesn't exist
if [ ! -f "$TASK_FILE" ]; then
  echo "[claude-start] Creating $TASK_FILE in $(pwd)..."
  cat > "$TASK_FILE" <<'TASKEOF'
# Claude Task Queue

Tasks are processed top-to-bottom.
- `[ ]` = pending
- `[!]` = in progress (do not edit)
- `[x]` = done
- `[-]` = failed

__________________________________________________________________________

TASKEOF
  echo "[claude-start] Add tasks as: [ ] Your task description here"
fi

# ─── Branch & remote validation (before launching anything!) ───────────────

if [ -z "$BRANCH" ]; then
  BRANCH=$(git branch --show-current 2>/dev/null || true)
  if [ -z "$BRANCH" ]; then
    fail "ERROR: Could not detect current branch (detached HEAD?). Specify one with: --branch <name>"
  fi
fi

if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  ERROR: You're on the '$BRANCH' branch!"
  echo ""
  echo "  Big Mamma REFUSES to push to '$BRANCH'. Use a dev branch."
  echo ""
  echo "  Fix:  git checkout -b my-feature"
  echo "  Or:   ./claude-start.sh --branch my-feature"
  echo "══════════════════════════════════════════════════════════════"
  echo ""
  fail ""
fi

if ! git remote get-url origin &>/dev/null; then
  fail "ERROR: No 'origin' remote configured. Add one with: git remote add origin <url>"
fi

# ─── Duplicate instance protection ──────────────────────────────────────────

if [ -f "$LOCK_FILE" ]; then
  OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null)
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "ERROR: The House is already open! (PID $OLD_PID)"
    echo "       Close it first:  kill $OLD_PID"
    echo "       Or remove lock:  rm $LOCK_FILE"
    fail ""
  else
    echo "WARNING: Found a stale key in the lock (PID $OLD_PID not running). Removing."
    rm -f "$LOCK_FILE"
  fi
fi

echo $$ > "$LOCK_FILE"

# ─── Cleanup on exit ────────────────────────────────────────────────────────

WORKER_PID=""
SUPERVISOR_PID=""
QA_PID=""
TAIL_PID=""
CLEANING_UP=false

cleanup() {
  # Prevent re-entrant cleanup (trap EXIT fires after trap INT/TERM)
  if [ "$CLEANING_UP" = true ]; then
    return
  fi
  CLEANING_UP=true

  echo ""
  echo "👩🏽 Big Mamma: \"ALRIGHT! Lights OUT! Everybody GO HOME!\""
  echo ""
  [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null
  [ -n "$WORKER_PID" ] && kill "$WORKER_PID" 2>/dev/null && echo "  🐱 Tom dragged away from the keyboard (PID $WORKER_PID)"
  [ -n "$QA_PID" ] && kill "$QA_PID" 2>/dev/null && echo "  🐶 Spike called off patrol (PID $QA_PID)"
  [ -n "$SUPERVISOR_PID" ] && kill "$SUPERVISOR_PID" 2>/dev/null && echo "  👩🏽 Big Mamma hangs up her apron (PID $SUPERVISOR_PID)"
  rm -f "$LOCK_FILE"
  rm -f .claude-worker.pid .worker-status .qa-status .parallel-status-*
  rm -rf .tasks.lock .worktrees
  rm -f .worker-hibernate
  wait 2>/dev/null
  echo ""
  echo "🏠 The House is closed. Good night, everybody!"
}

trap cleanup INT TERM EXIT

# ─── Launch ──────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║   🏠  THE HOUSE  —  Tom, Jerry & Big Mamma                   ║"
echo "║   ──────────────────────────────────────────                  ║"
echo "║                                                              ║"
echo "║   👩🏽  Big Mamma ........... Supervisor (runs the house)      ║"
echo "║   🐱  Tom the Cat .......... Primary Worker (chases tasks)    ║"
echo "║   🐭  Jerry x2 ............. Parallel Workers (sneaky fast)   ║"
echo "║   🐶  Spike the Bulldog .... QA Enforcer (checks quality)    ║"
echo "║                                                              ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Location:   $(pwd)"
echo "║  Scripts:    $SCRIPT_DIR"
echo "║  Tasks:      $TASK_FILE"
echo "║  Branch:     ${BRANCH:-auto-detect}"
echo "║  Auto mode:  ${AUTO_MODE:-off}"
echo "║  Merge main: ${MERGE_MAIN:-off}"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                              ║"
echo "║  \"If I've told you once, I've told you a THOUSAND times...\" ║"
echo "║                                          — Big Mamma         ║"
echo "║                                                              ║"
echo "║  Ctrl+C = Big Mamma kicks everyone out                      ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Ensure log files exist before tail -f
touch claude-worker.log claude-qa.log claude-supervisor.log 2>/dev/null

# Start Tom (stdout -> /dev/null, stderr -> log so crashes are visible)
bash "$SCRIPT_DIR/claude-worker.sh" "$TASK_FILE" $AUTO_MODE > /dev/null 2>> claude-worker.log &
WORKER_PID=$!
echo "🐱 Tom the Cat enters the house (PID $WORKER_PID)"
echo "   \"Alright, where are those tasks...\""

# Start Spike
bash "$SCRIPT_DIR/claude-qa.sh" "$TASK_FILE" > /dev/null 2>> claude-qa.log &
QA_PID=$!
echo "🐶 Spike the Bulldog takes his post (PID $QA_PID)"
echo "   *growl* \"I'm watching you, Tom.\""

# Small delay so Tom grabs first task before Big Mamma checks
sleep 3

# Start Big Mamma
bash "$SCRIPT_DIR/claude-supervisor.sh" "$BRANCH" "$TASK_FILE" "$MERGE_MAIN" "$AUTO_MODE" > /dev/null 2>> claude-supervisor.log &
SUPERVISOR_PID=$!
echo "👩🏽 Big Mamma enters the house (PID $SUPERVISOR_PID)"
echo "   \"Now y'all better BEHAVE yourselves!\""

echo ""
echo "🏠 The House is OPEN! Watching logs..."
echo "════════════════════════════════════════════════════════════════"

# Tail all logs together
tail -f claude-worker.log claude-qa.log claude-supervisor.log 2>/dev/null &
TAIL_PID=$!

# Wait for all to keep running — if Tom or Big Mamma dies, close the house
while true; do
  if ! kill -0 "$WORKER_PID" 2>/dev/null; then
    echo ""
    echo "🐱💀 Tom has left the building unexpectedly!"
    echo "   Big Mamma: \"THOMAS?! Where did that cat GO?!\""
    echo ""
    echo "   ── Last lines from claude-worker.log ──"
    tail -8 claude-worker.log 2>/dev/null || echo "   (no log available)"
    echo "   ────────────────────────────────────────"
    break
  fi
  if ! kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
    echo ""
    echo "👩🏽💀 Big Mamma has left the building unexpectedly!"
    echo "   Tom: \"...Big Mamma? ...is she gone? ...FREEDOM!\""
    echo "   Spike: \"Not so fast, pussycat.\""
    echo ""
    echo "   ── Last lines from claude-supervisor.log ──"
    tail -8 claude-supervisor.log 2>/dev/null || echo "   (no log available)"
    echo "   ─────────────────────────────────────────────"
    break
  fi
  # Restart Spike if he wanders off (non-critical — shouldn't block work)
  if ! kill -0 "$QA_PID" 2>/dev/null; then
    echo "🐶 Spike wandered off — whistling him back..."
    bash "$SCRIPT_DIR/claude-qa.sh" "$TASK_FILE" > /dev/null 2>> claude-qa.log &
    QA_PID=$!
    echo "🐶 Spike is back on patrol (PID $QA_PID)"
    echo "   *shake* \"Sorry, thought I saw a squirrel.\""
  fi
  sleep 5
done

# If one dies, close the house
cleanup
exit 1
