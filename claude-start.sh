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
#   ./claude-start.sh --jerries 4                         # spawn 4 parallel Jerry workers
#   ./claude-start.sh --jerries 0                         # disable parallel workers
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
JERRIES=2
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
    --jerries|-j)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        fail "ERROR: --jerries requires a value.  Usage: --jerries <count>"
      fi
      JERRIES="$2"; shift 2 ;;
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

## Mamma Instructions

<!-- Project context for Big Mamma — helps her understand the codebase and delegate tasks better.
     Describe the project structure, tech stack, key conventions, and anything that affects
     how tasks should be split or ordered. Big Mamma reads this before every delegation decision. -->

__________________________________________________________________________

TASKEOF
  echo "[claude-start] Add tasks as: [ ] Your task description here"
fi

# Pick up or create CLAUDE.md, then inject Big Mamma's task-writing instructions
MAMMA_MARKER="<!-- BIG-MAMMA-TASK-INSTRUCTIONS -->"

if [ ! -f "CLAUDE.md" ]; then
  echo "[claude-start] No CLAUDE.md found — creating one in $(pwd)..."
  touch "CLAUDE.md"
fi

# Inject task-writing instructions if not already present
if ! grep -qF "$MAMMA_MARKER" "CLAUDE.md" 2>/dev/null; then
  echo "[claude-start] Injecting Big Mamma's task-writing instructions into CLAUDE.md..."
  cat >> "CLAUDE.md" <<'CLAUDEEOF'

<!-- BIG-MAMMA-TASK-INSTRUCTIONS -->
## Task Queue System (Big Mamma)

This project uses an autonomous task queue system. When asked to create, populate,
or update TASKS.md, follow these rules precisely.

### TASKS.md Format

```
# Claude Task Queue

Tasks are processed top-to-bottom.
- `[ ]` = pending
- `[!]` = in progress (do not edit)
- `[x]` = done
- `[-]` = failed

## Mamma Instructions

<Write project context here — see section below>

__________________________________________________________________________

[ ] First task
[ ] Second task
```

### Writing Tasks

- One task per line, prefixed with `[ ] `
- Tasks are executed **sequentially top-to-bottom** by an autonomous Claude worker (Tom)
  that has no memory between tasks — each task is a fresh `claude -p` invocation
- Each task MUST be **self-contained**: include enough context that a fresh Claude
  instance can complete it without knowing what came before
- Reference specific file paths, function names, or patterns when possible
- Avoid vague tasks like "refactor the code" — be precise about what to change and where
- Order tasks so dependencies come first (e.g., "create the util" before "use the util")
- Keep tasks atomic — one clear objective per task. If a task has "and" in it,
  consider splitting it into two tasks
- A parallel worker (Jerry) may pick up independent tasks concurrently — tasks that
  touch different files/features can run in parallel automatically

### Writing Mamma Instructions

The `## Mamma Instructions` section is **critical** — Big Mamma reads it before every
delegation decision. Write it as plain text (not HTML comments) between the heading
and the separator line. Include:

- **Project type & tech stack** (e.g., "Next.js 14 app with Python FastAPI backend")
- **Directory structure** (e.g., "frontend in /app, API in /server, shared types in /types")
- **Key conventions** (e.g., "use Zustand for state, all API routes in /server/routes")
- **Dependency order** (e.g., "database migrations must run before seed tasks")
- **Files that should NOT be touched** (e.g., "do not modify /config/production.yml")
- **Testing expectations** (e.g., "every new component needs a test in __tests__/")

Example:
```
## Mamma Instructions

React 18 + TypeScript frontend with Express backend. Frontend in /src, backend in /api.
Styling uses Tailwind CSS — no CSS modules. State management with Zustand stores in /src/stores.
API client is auto-generated from OpenAPI spec — do not edit /src/api/generated/.
Tests use Vitest — run with `pnpm test`. Every new utility needs a test.
Database is PostgreSQL with Drizzle ORM — migrations in /api/drizzle/.
```

Big Mamma uses this context to decide which tasks can safely run in parallel
and to give Jerry workers the right context when they work in isolated worktrees.
<!-- END-BIG-MAMMA-TASK-INSTRUCTIONS -->
CLAUDEEOF
  echo "[claude-start] ✓ CLAUDE.md now has task-writing instructions."
else
  echo "[claude-start] CLAUDE.md already has Big Mamma's instructions. ✓"
fi

# ─── Validate Jerry count ────────────────────────────────────────────────────

if ! [[ "$JERRIES" =~ ^[0-9]+$ ]] || [ "$JERRIES" -lt 0 ]; then
  fail "ERROR: --jerries must be a non-negative integer (got: $JERRIES)"
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

# ─── Register with dashboard ───────────────────────────────────────────────

INSTANCES_FILE="$SCRIPT_DIR/.house-instances"
# Use Windows path on Git Bash so it matches the dashboard's format
CURRENT_DIR="$(pwd -W 2>/dev/null || pwd)"
CURRENT_DIR="${CURRENT_DIR//\\//}"
# Add to registry if not already there
grep -qxF "$CURRENT_DIR" "$INSTANCES_FILE" 2>/dev/null || echo "$CURRENT_DIR" >> "$INSTANCES_FILE"

# ─── Cleanup on exit ────────────────────────────────────────────────────────

WORKER_PID=""
SUPERVISOR_PID=""
QA_PID=""
TAIL_PID=""
CLEANING_UP=false
SPIKE_LAST_RESTART=0

# Kill a process and all its children (tree kill on Windows).
# On MSYS2, plain `kill` only terminates the bash wrapper — native
# child processes (node.exe/claude) survive as orphans. taskkill /T
# kills the entire tree.
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

cleanup() {
  # Prevent re-entrant cleanup (trap EXIT fires after trap INT/TERM)
  if [ "$CLEANING_UP" = true ]; then
    return
  fi
  CLEANING_UP=true

  echo ""
  echo "👩🏽 Big Mamma: \"ALRIGHT! Lights OUT! Everybody GO HOME!\""
  echo ""

  # Deregister from dashboard
  INSTANCES_FILE="$SCRIPT_DIR/.house-instances"
  CURRENT_DIR="$(pwd -W 2>/dev/null || pwd)"
  CURRENT_DIR="${CURRENT_DIR//\\//}"
  if [ -f "$INSTANCES_FILE" ]; then
    grep -vxF "$CURRENT_DIR" "$INSTANCES_FILE" > "$INSTANCES_FILE.tmp" 2>/dev/null
    mv -f "$INSTANCES_FILE.tmp" "$INSTANCES_FILE" 2>/dev/null
  fi

  [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null
  [ -n "$WORKER_PID" ] && kill_tree "$WORKER_PID" && echo "  🐱 Tom dragged away from the keyboard (PID $WORKER_PID)"
  [ -n "$QA_PID" ] && kill_tree "$QA_PID" && echo "  🐶 Spike called off patrol (PID $QA_PID)"
  [ -n "$SUPERVISOR_PID" ] && kill_tree "$SUPERVISOR_PID" && echo "  👩🏽 Big Mamma hangs up her apron (PID $SUPERVISOR_PID)"
  rm -f "$LOCK_FILE"
  rm -f .claude-worker.pid .claude-supervisor.pid .claude-qa.pid .worker-status .qa-status .parallel-status-*
  rm -rf .tasks.lock .worktrees
  rm -f .worker-hibernate .house-jerries
  wait 2>/dev/null
  echo ""
  echo "🏠 The House is closed. Good night, everybody!"
}

trap cleanup EXIT
trap 'cleanup; exit 1' INT TERM

# ─── Launch ──────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                                                              ║"
echo "║   🏠  THE HOUSE  —  Tom, Jerry & Big Mamma                   ║"
echo "║   ──────────────────────────────────────────                  ║"
echo "║                                                              ║"
echo "║   👩🏽  Big Mamma ........... Supervisor (runs the house)      ║"
echo "║   🐱  Tom the Cat .......... Primary Worker (chases tasks)    ║"
if [ "$JERRIES" -eq 0 ]; then
echo "║   🐭  Jerry ................ Not deployed                      ║"
else
echo "║   🐭  Jerry x${JERRIES} ............. Parallel Workers (sneaky fast)   ║"
fi
echo "║   🐶  Spike the Bulldog .... QA Enforcer (checks quality)    ║"
echo "║                                                              ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Location:   $(pwd)"
echo "║  Scripts:    $SCRIPT_DIR"
echo "║  Tasks:      $TASK_FILE"
echo "║  CLAUDE.md:  $([ -f 'CLAUDE.md' ] && echo '✓ loaded' || echo '✗ not found')"
echo "║  Branch:     ${BRANCH:-auto-detect}"
echo "║  Jerries:    ${JERRIES}"
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

# Write Jerry count so other scripts + UI can read it
echo "$JERRIES" > .house-jerries

# Rotate old logs if they're too large (>1MB)
for logfile in claude-worker.log claude-qa.log claude-supervisor.log claude-supervisor-verbose.log claude-worker-output.log claude-parallel-*.log; do
  if [ -f "$logfile" ]; then
    LOG_SIZE=$(wc -c < "$logfile" 2>/dev/null | tr -d ' ')
    if [ "${LOG_SIZE:-0}" -gt 1048576 ]; then
      mv "$logfile" "${logfile}.old" 2>/dev/null || true
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Log rotated on startup (was ${LOG_SIZE} bytes)" > "$logfile"
    fi
  fi
done

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
echo "$QA_PID" > .claude-qa.pid
echo "🐶 Spike the Bulldog takes his post (PID $QA_PID)"
echo "   *growl* \"I'm watching you, Tom.\""

# Small delay so Tom grabs first task before Big Mamma checks
sleep 3

# Start Big Mamma
bash "$SCRIPT_DIR/claude-supervisor.sh" "$BRANCH" "$TASK_FILE" "$MERGE_MAIN" "$AUTO_MODE" "$JERRIES" > /dev/null 2>> claude-supervisor.log &
SUPERVISOR_PID=$!
echo "$SUPERVISOR_PID" > .claude-supervisor.pid
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
  # Backoff: don't restart more than once per 60 seconds to avoid fork bombs
  if ! kill -0 "$QA_PID" 2>/dev/null; then
    SPIKE_NOW=$(date +%s)
    SPIKE_ELAPSED=$(( SPIKE_NOW - ${SPIKE_LAST_RESTART:-0} ))
    if [ "$SPIKE_ELAPSED" -ge 60 ]; then
      echo "🐶 Spike wandered off — whistling him back..."
      bash "$SCRIPT_DIR/claude-qa.sh" "$TASK_FILE" > /dev/null 2>> claude-qa.log &
      QA_PID=$!
      echo "$QA_PID" > .claude-qa.pid
      SPIKE_LAST_RESTART=$SPIKE_NOW
      echo "🐶 Spike is back on patrol (PID $QA_PID)"
      echo "   *shake* \"Sorry, thought I saw a squirrel.\""
    fi
  fi
  sleep 5
done

# If one dies, close the house
cleanup
exit 1
