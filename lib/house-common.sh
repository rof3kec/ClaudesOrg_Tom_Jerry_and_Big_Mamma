#!/usr/bin/env bash
# lib/house-common.sh — Shared library for The House
#
# Source this file from any house script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib/house-common.sh"
#
# Before sourcing, the caller MUST set:
#   LOG_FILE     — path to the script's log file
#   LOG_PREFIX   — e.g., "[BIG MAMMA]", "[TOM]", "[SPIKE]"
#
# Optional (have defaults):
#   TASK_FILE    — defaults to "TASKS.md"
#   LOCK_DIR     — defaults to ".tasks.lock"

# Guard against double-sourcing
[[ -n "${_HOUSE_COMMON_LOADED:-}" ]] && return 0
_HOUSE_COMMON_LOADED=1

# ─── Constants ─────────────────────────────────────────────────────────────────

LOCK_DIR="${LOCK_DIR:-.tasks.lock}"
HIBERNATE_FILE="${HIBERNATE_FILE:-.worker-hibernate}"
WORKER_STATUS_FILE="${WORKER_STATUS_FILE:-.worker-status}"
QA_STATUS_FILE="${QA_STATUS_FILE:-.qa-status}"
WORKER_PID_FILE="${WORKER_PID_FILE:-.claude-worker.pid}"
MAX_LOG_SIZE="${MAX_LOG_SIZE:-1048576}"    # 1MB

# ─── ANSI Colors ───────────────────────────────────────────────────────────────

_C_RST=$'\033[0m'
_C_BLUE=$'\033[1;94m'
_C_GREEN=$'\033[1;92m'
_C_RED=$'\033[1;91m'
_C_YELLOW=$'\033[1;93m'

# ─── Logging ───────────────────────────────────────────────────────────────────

house_log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ${LOG_PREFIX:-[HOUSE]} $*"
  echo "$msg"
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "$msg" >> "$LOG_FILE"
  fi
}

house_die() {
  house_log "FATAL: $*"
  exit 1
}

# ─── Text Helpers ──────────────────────────────────────────────────────────────

short() {
  local w
  w=$(echo "$1" | wc -w | tr -d ' ')
  if [ "$w" -gt 10 ]; then
    echo "$1" | cut -d' ' -f1-10 | sed 's/$/ (...)/'
  else
    echo "$1"
  fi
}

# ─── Cross-platform sed -i ────────────────────────────────────────────────────
# Replaces 15 occurrences of the OSTYPE check pattern across all scripts.

sedi() {
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# ─── File Locking (mkdir is atomic on all platforms) ───────────────────────────

lock_tasks() {
  local attempts=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    sleep 0.5
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 20 ]; then
      house_log "WARNING: Task lock timeout after 10s, forcing unlock"
      rm -rf "$LOCK_DIR"
      mkdir "$LOCK_DIR" 2>/dev/null || true
      return
    fi
  done
}

unlock_tasks() {
  rm -rf "$LOCK_DIR"
}

# ─── Process Management (cross-platform) ──────────────────────────────────────

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

is_process_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null && return 0
  ps -p "$pid" > /dev/null 2>&1 && return 0
  return 1
}

# ─── Status File I/O ──────────────────────────────────────────────────────────

# Read a KEY=VALUE status file. Sets variables prefixed with the given prefix.
# Usage: read_kv ".worker-status"  → sets KV_STATE, KV_WORKER_PID, etc.
# Returns 1 if file does not exist.
read_kv() {
  local file="$1"
  [ -f "$file" ] || return 1
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    printf -v "KV_${key}" '%s' "$value"
  done < "$file"
  return 0
}

# ─── Log Rotation ─────────────────────────────────────────────────────────────

rotate_log_if_needed() {
  local file="$1"
  [ -f "$file" ] || return
  local size
  size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
  if [ "${size:-0}" -gt "$MAX_LOG_SIZE" ]; then
    mv "$file" "${file}.old" 2>/dev/null || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${LOG_PREFIX:-[HOUSE]} Log rotated (was ${size} bytes)" > "$file"
  fi
}

# ─── Section-aware Task Selection ──────────────────────────────────────────────
# Finds the first ## section (after the separator) with incomplete tasks
# ([ ], [!], or [-]). Sets ACTIVE_SECTION_START, ACTIVE_SECTION_END (line
# numbers, inclusive), and ACTIVE_SECTION_NAME.
# If no ## headings exist after the separator, the whole area is one section.
# Returns 1 if no active section found.

find_active_section() {
  local task_file="$1"
  local sep_line="${2:-0}"
  ACTIVE_SECTION_START=0
  ACTIVE_SECTION_END=0
  ACTIVE_SECTION_NAME=""

  local total_lines
  total_lines=$(wc -l < "$task_file" 2>/dev/null | tr -d ' ')
  total_lines="${total_lines:-0}"
  [ "$total_lines" -eq 0 ] && return 1

  # Collect ## heading line numbers after the separator
  local -a sec_starts=()
  local -a sec_names=()
  while IFS= read -r heading; do
    local hline hname
    hline=$(echo "$heading" | cut -d: -f1)
    if [ "$hline" -gt "$sep_line" ]; then
      hname=$(echo "$heading" | sed 's/^[0-9]*:## //')
      sec_starts+=("$hline")
      sec_names+=("$hname")
    fi
  done < <(grep -n '^## ' "$task_file" 2>/dev/null || true)

  # No sections: treat everything after separator as one flat section
  if [ ${#sec_starts[@]} -eq 0 ]; then
    ACTIVE_SECTION_START=$((sep_line + 1))
    ACTIVE_SECTION_END=$total_lines
    ACTIVE_SECTION_NAME="(all tasks)"
    if sed -n "${ACTIVE_SECTION_START},${ACTIVE_SECTION_END}p" "$task_file" 2>/dev/null | grep -qE '^\[[ !-]\] '; then
      return 0
    fi
    return 1
  fi

  # Check for ungrouped tasks between separator and first heading
  local first_sec="${sec_starts[0]}"
  if [ "$first_sec" -gt $((sep_line + 1)) ]; then
    local range_start=$((sep_line + 1))
    local range_end=$((first_sec - 1))
    if sed -n "${range_start},${range_end}p" "$task_file" 2>/dev/null | grep -qE '^\[[ !-]\] '; then
      ACTIVE_SECTION_START=$range_start
      ACTIVE_SECTION_END=$range_end
      ACTIVE_SECTION_NAME="(ungrouped)"
      return 0
    fi
  fi

  # Check each section in order — first with incomplete tasks wins
  for ((si=0; si<${#sec_starts[@]}; si++)); do
    local s_start="${sec_starts[$si]}"
    local s_end
    if [ $((si + 1)) -lt ${#sec_starts[@]} ]; then
      s_end=$(( ${sec_starts[$((si + 1))]} - 1 ))
    else
      s_end=$total_lines
    fi
    if sed -n "${s_start},${s_end}p" "$task_file" 2>/dev/null | grep -qE '^\[[ !-]\] '; then
      ACTIVE_SECTION_START=$s_start
      ACTIVE_SECTION_END=$s_end
      ACTIVE_SECTION_NAME="${sec_names[$si]}"
      return 0
    fi
  done

  return 1
}
