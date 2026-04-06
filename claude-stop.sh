#!/usr/bin/env bash
# claude-stop.sh — Big Mamma says: "EVERYBODY OUT! This house is CLOSING!"
#
# Usage:
#   ./claude-stop.sh                                    # kill ALL houses, everywhere
#   ./claude-stop.sh --force                            # use SIGKILL (the rolling pin)
#   ./claude-stop.sh --location D:/Projects/MyApp       # stop ONLY this location
#   ./claude-stop.sh --force --location D:/Projects/MyApp

set -u

SIGNAL="TERM"
LOCATION=""

# ─── Parse args ──────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|-f)      SIGNAL="KILL"; echo "👩🏽🔨 Big Mamma grabbed the ROLLING PIN (SIGKILL mode)"; shift ;;
    --location|-l)   LOCATION="$2"; shift 2 ;;
    *)               echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ─── Change to project location ─────────────────────────────────────────────

if [ -n "$LOCATION" ]; then
  LOCATION=$(echo "$LOCATION" | sed 's|\\|/|g; s|//|/|g')
  if [ ! -d "$LOCATION" ]; then
    echo "ERROR: Location '$LOCATION' does not exist."
    exit 1
  fi
  cd "$LOCATION" || { echo "ERROR: Cannot cd to '$LOCATION'"; exit 1; }
  echo "[claude-stop] Working directory: $(pwd)"
fi

# ─── Kill helper ─────────────────────────────────────────────────────────────

KILLED=0

# Cross-platform kill: on Windows/MSYS, kill -9 often doesn't work.
# Resolve the real Windows PID via /proc/<pid>/winpid and use taskkill.
kill_pid() {
  local pid="$1"
  local label="$2"

  # Check if process is still alive first
  if ! kill -0 "$pid" 2>/dev/null; then
    return
  fi

  # On Windows/MSYS2: ALWAYS use taskkill /T /F for process tree kill.
  # Plain `kill` only terminates the MSYS2 bash wrapper process;
  # native child processes (node.exe running claude) survive as orphans.
  # /T = kill entire process tree (children too), /F = force (required for console apps).
  if [ -f "/proc/$pid/winpid" ]; then
    local winpid
    winpid=$(cat "/proc/$pid/winpid" 2>/dev/null || true)
    if [ -n "$winpid" ]; then
      if taskkill //T //F //PID "$winpid" > /dev/null 2>&1; then
        KILLED=$((KILLED + 1))
        echo "[claude-stop] Sent $label + all children home (PID $pid -> WinPID $winpid, tree kill)"
        return
      fi
    fi
  fi

  # Unix / fallback: standard signal
  if kill -"$SIGNAL" "$pid" 2>/dev/null; then
    KILLED=$((KILLED + 1))
    echo "[claude-stop] Sent $label home (PID $pid)"
    return
  fi

  echo "[claude-stop] $label refused to leave (PID $pid)"
}

# Read a PID from a file and kill it
kill_from_file() {
  local file="$1"
  local label="$2"
  [ -f "$file" ] || return
  local pid
  pid=$(cat "$file" 2>/dev/null || true)
  [ -n "$pid" ] && kill_pid "$pid" "$label"
}

# Read a PID from a KEY=VALUE status file and kill it
kill_from_status() {
  local file="$1"
  local key="$2"
  local label="$3"
  [ -f "$file" ] || return
  local pid
  pid=$(grep "^${key}=" "$file" 2>/dev/null | cut -d= -f2)
  [ -n "$pid" ] && kill_pid "$pid" "$label"
}

# ─── Kill processes ──────────────────────────────────────────────────────────

echo ""
echo "👩🏽 Big Mamma: \"ALRIGHT! Party's OVER! Everybody OUT!\""
echo ""

if [ -n "$LOCATION" ]; then
  # ── Location-scoped stop ────────────────────────────────────────────────
  # Only kills processes belonging to THIS house instance, using PID files
  # written to the project directory. Other locations are left alone.

  START_PID=""
  [ -f ".claude-start.lock" ] && START_PID=$(cat ".claude-start.lock" 2>/dev/null || true)

  if [ "$SIGNAL" = "TERM" ] && [ -n "$START_PID" ]; then
    # Graceful stop: SIGTERM to the House Manager triggers its cleanup trap,
    # which kills Tom, Big Mamma, Spike, tail, and removes PID files.
    kill_pid "$START_PID" "🏠 House Manager"
    # Give the trap handler a moment to clean up children
    sleep 2
  else
    # Force stop (SIGKILL) or no lock file — kill each process from PID files.
    # SIGKILL doesn't trigger traps, so we must hunt down each process.
    [ -n "$START_PID" ] && kill_pid "$START_PID" "🏠 House Manager"

    # Tom (primary worker)
    kill_from_status ".worker-status" "WORKER_PID" "🐱 Tom (worker)"
    kill_from_status ".worker-status" "CLAUDE_PID" "🐱 Tom (claude)"
    kill_from_file   ".claude-worker.pid"           "🐱 Tom (claude)"

    # Big Mamma (supervisor)
    kill_from_file ".claude-supervisor.pid" "👩🏽 Big Mamma"

    # Spike (QA)
    kill_from_file ".claude-qa.pid" "🐶 Spike"
  fi

else
  # ── Global stop (no --location) — kill ALL matching processes ──────────
  # Nuclear option: finds and kills every house process on the system.
  for pattern in "claude-worker.sh" "claude-supervisor.sh" "claude-qa.sh" "claude-start.sh"; do
    PIDS=$(ps -ef 2>/dev/null | grep "$pattern" | grep -v grep | awk '{print $2}' || true)
    if [ -n "$PIDS" ]; then
      for pid in $PIDS; do
        case "$pattern" in
          "claude-worker.sh")     kill_pid "$pid" "🐱 Tom" ;;
          "claude-supervisor.sh") kill_pid "$pid" "👩🏽 Big Mamma" ;;
          "claude-qa.sh")         kill_pid "$pid" "🐶 Spike" ;;
          "claude-start.sh")      kill_pid "$pid" "🏠 House Manager" ;;
        esac
      done
    fi
  done

  # Kill any tail -f on our log files
  TAIL_PIDS=$(ps -ef 2>/dev/null | grep "tail -f claude-worker.log" | grep -v grep | awk '{print $2}' || true)
  if [ -n "$TAIL_PIDS" ]; then
    for pid in $TAIL_PIDS; do
      kill_pid "$pid" "log tail"
    done
  fi
fi

# ─── Sweep for orphaned claude processes (Windows safety net) ──────────────
# On Windows, even with tree kill, processes can escape if PID files are stale
# or the House Manager died before it could track children.
# For global stop or force mode: sweep for any surviving node.exe running claude.

if [ -f "/proc/self/winpid" ] && { [ -z "$LOCATION" ] || [ "$SIGNAL" = "KILL" ]; }; then
  echo "[claude-stop] 🔍 Sweeping for orphaned claude processes..."
  ORPHANS=$(wmic process where "Name='node.exe'" get CommandLine,ProcessId //FORMAT:CSV 2>/dev/null | \
    grep -i 'claude' | awk -F',' '{print $NF}' | tr -d '\r' | grep -oE '[0-9]+' || true)
  ORPHAN_COUNT=0
  for WPID in $ORPHANS; do
    [ -z "$WPID" ] && continue
    if taskkill //T //F //PID "$WPID" > /dev/null 2>&1; then
      ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
    fi
  done
  if [ "$ORPHAN_COUNT" -gt 0 ]; then
    KILLED=$((KILLED + ORPHAN_COUNT))
    echo "[claude-stop] 💀 Killed $ORPHAN_COUNT orphaned claude process(es)"
  fi
fi

# ─── Clean up stale files ───────────────────────────────────────────────────

rm -f .worker-hibernate .claude-worker.pid .claude-supervisor.pid .claude-qa.pid .worker-status .qa-status .parallel-status-* .house-jerries .claude-start.lock
rm -rf .tasks.lock

# ─── Reset in-progress tasks back to pending ───────────────────────────────
# Agents are dead — any [!] tasks were mid-flight and must return to [ ]

TASK_FILE="TASKS.md"
if [ -f "$TASK_FILE" ]; then
  STALE=$(grep -c '^\[!\] ' "$TASK_FILE" 2>/dev/null || true)
  if [ "${STALE:-0}" -gt 0 ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
      sed -i '' 's/^\[!\] /[ ] /' "$TASK_FILE"
    else
      sed -i 's/^\[!\] /[ ] /' "$TASK_FILE"
    fi
    echo "[claude-stop] Reset $STALE in-progress task(s) back to pending in $TASK_FILE"
  fi
fi

# Clean up parallel worktrees (Jerry's hideouts)
if [ -d ".worktrees" ]; then
  echo "[claude-stop] Cleaning up Jerry's worktree hideouts..."
  for wt in .worktrees/parallel-*; do
    [ -d "$wt" ] || continue
    branch=$(basename "$wt")
    git worktree remove "$wt" --force 2>/dev/null && echo "  Demolished hideout: $wt"
    git branch -D "$branch" 2>/dev/null && echo "  Sealed tunnel: $branch"
  done
  rmdir .worktrees 2>/dev/null || true
fi

echo ""
if [ "$KILLED" -eq 0 ]; then
  echo "👩🏽 Big Mamma: \"Hmm. House is already empty. Where IS everybody?\""
else
  echo "👩🏽 Big Mamma: \"$KILLED of y'all sent home. Now the house is QUIET.\""
fi
