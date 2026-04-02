#!/usr/bin/env bash
# claude-stop.sh — Big Mamma says: "EVERYBODY OUT! This house is CLOSING!"
#
# Usage:
#   ./claude-stop.sh                                    # kill all, cleanup in CWD
#   ./claude-stop.sh --force                            # use SIGKILL (the rolling pin)
#   ./claude-stop.sh --location D:/Projects/MyApp       # cleanup in a specific directory
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

  # Try native kill first
  if kill -"$SIGNAL" "$pid" 2>/dev/null; then
    KILLED=$((KILLED + 1))
    echo "[claude-stop] Sent $label home (PID $pid)"
    return
  fi

  # Fallback: resolve Windows PID and use taskkill
  local winpid
  winpid=$(cat "/proc/$pid/winpid" 2>/dev/null || true)
  if [ -n "$winpid" ]; then
    local flags="//PID $winpid"
    [ "$SIGNAL" = "KILL" ] && flags="//F $flags"
    if taskkill $flags > /dev/null 2>&1; then
      KILLED=$((KILLED + 1))
      echo "[claude-stop] Sent $label home (PID $pid -> WinPID $winpid)"
      return
    fi
  fi

  echo "[claude-stop] $label refused to leave (PID $pid)"
}

# ─── Kill processes ──────────────────────────────────────────────────────────

echo ""
echo "👩🏽 Big Mamma: \"ALRIGHT! Party's OVER! Everybody OUT!\""
echo ""

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

# ─── Clean up stale files ───────────────────────────────────────────────────

rm -f .worker-hibernate .claude-worker.pid .worker-status .qa-status .parallel-status-*
rm -rf .tasks.lock

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
