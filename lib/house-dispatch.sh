#!/usr/bin/env bash
# lib/house-dispatch.sh — 🧠 Smart Task Dispatch for Big Mamma
#
# Pre-Flight Task Analysis: Classifies tasks by complexity, file affinity,
# and conflicts to enable intelligent routing and maximize parallelism.
#
# Sourced by claude-supervisor.sh. Requires house-common.sh loaded first.
#
# Globals read:  TASK_FILE, AUTO_MODE, ACTIVE_SECTION_START, ACTIVE_SECTION_END
# Globals write: DISPATCH_ANALYZED_SECTION, TASK_COMPLEXITY[], TASK_FILES[],
#                TASK_TYPE[], TASK_ESTIMATED_TIME[], TASK_CONFLICT_CLUSTER[]

# Guard against double-sourcing
[[ -n "${_HOUSE_DISPATCH_LOADED:-}" ]] && return 0
_HOUSE_DISPATCH_LOADED=1

# ─── Dispatch State ────────────────────────────────────────────────────────
# Associative arrays for task metadata (indexed by task line number)

declare -A TASK_COMPLEXITY        # "light" | "medium" | "heavy"
declare -A TASK_FILES             # space-separated file paths task will touch
declare -A TASK_TYPE              # "bugfix" | "feature" | "refactor" | "config" | "test"
declare -A TASK_ESTIMATED_TIME    # estimated seconds to complete
declare -A TASK_CONFLICT_CLUSTER  # conflict group ID (tasks in same cluster = can't parallelize)

DISPATCH_ANALYZED_SECTION=""      # tracks which section was analyzed
DISPATCH_CACHE_FILE=".house-dispatch-cache"

# ─── Analysis Engine ───────────────────────────────────────────────────────

analyze_task_batch() {
  # Analyzes all pending tasks in the active section with ONE Claude call.
  # Returns 0 if analysis succeeded, 1 if failed or no tasks to analyze.

  local section_name="${1:-unknown}"
  local -a task_lines=()
  local -a task_descs=()

  # Skip if already analyzed this section
  if [ "$DISPATCH_ANALYZED_SECTION" = "$section_name" ]; then
    return 0
  fi

  house_log "🧠 Pre-flight analysis: examining pending tasks in '$section_name'..."

  # Collect all pending [ ] tasks in active section (with continuation lines)
  while IFS= read -r candidate; do
    local line_num
    line_num=$(echo "$candidate" | cut -d: -f1)
    [ "$line_num" -lt "$ACTIVE_SECTION_START" ] && continue
    [ "$line_num" -gt "$ACTIVE_SECTION_END" ] && break

    local task_desc
    task_desc=$(echo "$candidate" | sed 's/^[0-9]*:\[ \] //')

    # Read continuation lines
    local _cnext=$(( line_num + 1 ))
    while [ "$_cnext" -le "$ACTIVE_SECTION_END" ]; do
      local _ccont
      _ccont=$(sed -n "${_cnext}p" "$TASK_FILE")
      if [ -z "$_ccont" ] || echo "$_ccont" | grep -qE '^\[[ xXqQ!-]\] |^#+ |^_{5,}'; then
        break
      fi
      task_desc="${task_desc}
${_ccont}"
      _cnext=$((_cnext + 1))
    done

    # Skip status-like lines
    if echo "$task_desc" | grep -qiE '^(pending|done|in progress|failed|waiting)(\s|$)'; then
      continue
    fi

    task_lines+=("$line_num")
    task_descs+=("$task_desc")
  done < <(grep -n '^\[ \] ' "$TASK_FILE" 2>/dev/null || true)

  if [ ${#task_lines[@]} -eq 0 ]; then
    house_log "   🧠 No pending tasks to analyze in this section"
    DISPATCH_ANALYZED_SECTION="$section_name"
    return 1
  fi

  house_log "   🧠 Analyzing ${#task_lines[@]} task(s)..."

  # Build the analysis prompt
  local analysis_prompt="You are Big Mamma's task analysis assistant. Analyze the following tasks and return metadata for intelligent routing.

RULES:
- Analyze each task's complexity, files it will touch, type, and estimated completion time
- Complexity: 'light' (<1 min), 'medium' (1-5 min), 'heavy' (>5 min)
- Files: list SPECIFIC file paths the task will create/modify (e.g., 'src/api/routes.ts src/utils/helpers.ts')
- Type: 'bugfix', 'feature', 'refactor', 'config', 'test', 'docs'
- Estimated time: seconds (be realistic)
- Output EXACTLY this format for each task (no extra commentary):

TASK_LINE:<line_number>
COMPLEXITY:<light|medium|heavy>
FILES:<space-separated file paths or 'UNKNOWN' if truly unknowable>
TYPE:<bugfix|feature|refactor|config|test|docs>
ESTIMATED_TIME:<seconds>
---

TASKS TO ANALYZE:
"

  for ((i=0; i<${#task_lines[@]}; i++)); do
    analysis_prompt="${analysis_prompt}
Task #${task_lines[$i]}: ${task_descs[$i]}
"
  done

  # Run Claude analysis (skip permissions in auto mode)
  local claude_cmd="claude -p"
  [ "$AUTO_MODE" = "--auto" ] && claude_cmd="$claude_cmd --dangerously-skip-permissions"

  local analysis_output=""
  analysis_output=$($claude_cmd "$analysis_prompt" 2>&1) || {
    house_log "   🧠⚠ Analysis failed (Claude error). Falling back to conservative estimates."
    fallback_analysis "${task_lines[@]}"
    return 1
  }

  # Parse the output into associative arrays
  local current_line=""
  while IFS= read -r line; do
    case "$line" in
      TASK_LINE:*)
        current_line="${line#TASK_LINE:}"
        ;;
      COMPLEXITY:*)
        [ -n "$current_line" ] && TASK_COMPLEXITY[$current_line]="${line#COMPLEXITY:}"
        ;;
      FILES:*)
        [ -n "$current_line" ] && TASK_FILES[$current_line]="${line#FILES:}"
        ;;
      TYPE:*)
        [ -n "$current_line" ] && TASK_TYPE[$current_line]="${line#TYPE:}"
        ;;
      ESTIMATED_TIME:*)
        [ -n "$current_line" ] && TASK_ESTIMATED_TIME[$current_line]="${line#ESTIMATED_TIME:}"
        ;;
      ---*)
        current_line=""
        ;;
    esac
  done <<< "$analysis_output"

  # Detect conflict clusters (tasks that touch overlapping files)
  detect_conflict_clusters "${task_lines[@]}"

  # Cache the analysis
  save_dispatch_cache

  DISPATCH_ANALYZED_SECTION="$section_name"

  house_log "   🧠✓ Analysis complete: ${#task_lines[@]} tasks classified"
  log_analysis_summary "${task_lines[@]}"

  return 0
}

# ─── Conflict Detection ────────────────────────────────────────────────────

detect_conflict_clusters() {
  # Groups tasks by file overlap. Tasks in the same cluster can't run in parallel.
  local -a all_lines=("$@")
  local cluster_id=0

  # Reset clusters
  for line in "${all_lines[@]}"; do
    TASK_CONFLICT_CLUSTER[$line]=""
  done

  # For each task, check if it overlaps with any existing cluster
  for ((i=0; i<${#all_lines[@]}; i++)); do
    local line_i="${all_lines[$i]}"
    local files_i="${TASK_FILES[$line_i]:-}"

    # Skip if already clustered or no file info
    [ -n "${TASK_CONFLICT_CLUSTER[$line_i]}" ] && continue
    [ -z "$files_i" ] || [ "$files_i" = "UNKNOWN" ] && {
      TASK_CONFLICT_CLUSTER[$line_i]="solo-$line_i"
      continue
    }

    # Start a new cluster for this task
    cluster_id=$((cluster_id + 1))
    TASK_CONFLICT_CLUSTER[$line_i]="cluster-$cluster_id"

    # Find all other tasks that overlap with this one
    for ((j=i+1; j<${#all_lines[@]}; j++)); do
      local line_j="${all_lines[$j]}"
      local files_j="${TASK_FILES[$line_j]:-}"

      [ -z "$files_j" ] || [ "$files_j" = "UNKNOWN" ] && continue

      # Check for file overlap
      if files_overlap "$files_i" "$files_j"; then
        TASK_CONFLICT_CLUSTER[$line_j]="cluster-$cluster_id"
      fi
    done
  done
}

files_overlap() {
  # Returns 0 if two space-separated file lists have any common files
  local files_a="$1"
  local files_b="$2"

  for file_a in $files_a; do
    for file_b in $files_b; do
      [ "$file_a" = "$file_b" ] && return 0
    done
  done
  return 1
}

# ─── Fallback Analysis ────────────────────────────────────────────────────

fallback_analysis() {
  # Conservative estimates when Claude analysis fails
  local -a lines=("$@")

  for line in "${lines[@]}"; do
    TASK_COMPLEXITY[$line]="medium"
    TASK_FILES[$line]="UNKNOWN"
    TASK_TYPE[$line]="feature"
    TASK_ESTIMATED_TIME[$line]="180"
    TASK_CONFLICT_CLUSTER[$line]="solo-$line"
  done

  house_log "   🧠 Applied fallback: all tasks marked 'medium' complexity, no parallelism"
}

# ─── Cache Management ──────────────────────────────────────────────────────

save_dispatch_cache() {
  # Save analysis to file (for dashboard inspection and debugging)
  {
    echo "# Dispatch Analysis Cache"
    echo "# Generated: $(date)"
    echo "# Section: $DISPATCH_ANALYZED_SECTION"
    echo ""
    for line in "${!TASK_COMPLEXITY[@]}"; do
      echo "LINE=$line"
      echo "COMPLEXITY=${TASK_COMPLEXITY[$line]:-unknown}"
      echo "FILES=${TASK_FILES[$line]:-UNKNOWN}"
      echo "TYPE=${TASK_TYPE[$line]:-unknown}"
      echo "ESTIMATED_TIME=${TASK_ESTIMATED_TIME[$line]:-0}"
      echo "CONFLICT_CLUSTER=${TASK_CONFLICT_CLUSTER[$line]:-unknown}"
      echo "---"
    done
  } > "$DISPATCH_CACHE_FILE"
}

load_dispatch_cache() {
  # Load cached analysis (useful after Big Mamma restart)
  [ -f "$DISPATCH_CACHE_FILE" ] || return 1

  local current_line=""
  while IFS= read -r line; do
    case "$line" in
      \#*) continue ;;
      LINE=*)
        current_line="${line#LINE=}"
        ;;
      COMPLEXITY=*)
        [ -n "$current_line" ] && TASK_COMPLEXITY[$current_line]="${line#COMPLEXITY=}"
        ;;
      FILES=*)
        [ -n "$current_line" ] && TASK_FILES[$current_line]="${line#FILES=}"
        ;;
      TYPE=*)
        [ -n "$current_line" ] && TASK_TYPE[$current_line]="${line#TYPE=}"
        ;;
      ESTIMATED_TIME=*)
        [ -n "$current_line" ] && TASK_ESTIMATED_TIME[$current_line]="${line#ESTIMATED_TIME=}"
        ;;
      CONFLICT_CLUSTER=*)
        [ -n "$current_line" ] && TASK_CONFLICT_CLUSTER[$current_line]="${line#CONFLICT_CLUSTER=}"
        ;;
      ---*)
        current_line=""
        ;;
    esac
  done < "$DISPATCH_CACHE_FILE"

  return 0
}

clear_dispatch_cache() {
  # Clear analysis when section changes
  TASK_COMPLEXITY=()
  TASK_FILES=()
  TASK_TYPE=()
  TASK_ESTIMATED_TIME=()
  TASK_CONFLICT_CLUSTER=()
  DISPATCH_ANALYZED_SECTION=""
  rm -f "$DISPATCH_CACHE_FILE"
}

# ─── Query Functions ───────────────────────────────────────────────────────

get_task_complexity() {
  local line="$1"
  echo "${TASK_COMPLEXITY[$line]:-medium}"
}

get_task_files() {
  local line="$1"
  echo "${TASK_FILES[$line]:-UNKNOWN}"
}

get_task_type() {
  local line="$1"
  echo "${TASK_TYPE[$line]:-feature}"
}

get_task_estimated_time() {
  local line="$1"
  echo "${TASK_ESTIMATED_TIME[$line]:-180}"
}

get_task_conflict_cluster() {
  local line="$1"
  echo "${TASK_CONFLICT_CLUSTER[$line]:-solo-$line}"
}

can_parallelize_with() {
  # Returns 0 if task A can run in parallel with task B (no file conflicts)
  local line_a="$1"
  local line_b="$2"

  local cluster_a="${TASK_CONFLICT_CLUSTER[$line_a]:-}"
  local cluster_b="${TASK_CONFLICT_CLUSTER[$line_b]:-}"

  # If either is unknown, be conservative
  [ -z "$cluster_a" ] || [ -z "$cluster_b" ] && return 1

  # Solo tasks can parallelize with anyone except themselves
  [[ "$cluster_a" == solo-* ]] && [[ "$cluster_b" == solo-* ]] && [ "$line_a" != "$line_b" ] && return 0

  # Different clusters = safe to parallelize
  [ "$cluster_a" != "$cluster_b" ] && return 0

  # Same cluster = conflict
  return 1
}

# ─── Analysis Summary Logging ──────────────────────────────────────────────

log_analysis_summary() {
  local -a lines=("$@")
  local light=0 medium=0 heavy=0
  local clusters=0

  for line in "${lines[@]}"; do
    case "${TASK_COMPLEXITY[$line]:-}" in
      light) light=$((light + 1)) ;;
      medium) medium=$((medium + 1)) ;;
      heavy) heavy=$((heavy + 1)) ;;
    esac
  done

  # Count unique clusters
  local -A seen_clusters
  for line in "${lines[@]}"; do
    local cluster="${TASK_CONFLICT_CLUSTER[$line]:-}"
    [ -n "$cluster" ] && seen_clusters[$cluster]=1
  done
  clusters=${#seen_clusters[@]}

  house_log "   🧠 Breakdown: $light light, $medium medium, $heavy heavy | $clusters conflict cluster(s)"

  # Log conflicts if any
  if [ "$clusters" -gt 0 ] && [ "$clusters" -lt "${#lines[@]}" ]; then
    house_log "   🧠 Parallelism: Safe — conflict-aware routing enabled"
  elif [ "$clusters" -eq "${#lines[@]}" ]; then
    house_log "   🧠 Parallelism: Maximum — all tasks independent!"
  else
    house_log "   🧠 Parallelism: Limited — tasks share file dependencies"
  fi
}

# ─── Debug/Inspection ──────────────────────────────────────────────────────

dump_dispatch_state() {
  # Debug function to print current dispatch state
  house_log "🧠 Dispatch State Dump:"
  house_log "   Analyzed section: ${DISPATCH_ANALYZED_SECTION:-none}"
  house_log "   Tracked tasks: ${#TASK_COMPLEXITY[@]}"

  for line in "${!TASK_COMPLEXITY[@]}"; do
    house_log "   Task #$line:"
    house_log "      Complexity: ${TASK_COMPLEXITY[$line]}"
    house_log "      Files: ${TASK_FILES[$line]}"
    house_log "      Type: ${TASK_TYPE[$line]}"
    house_log "      Est. time: ${TASK_ESTIMATED_TIME[$line]}s"
    house_log "      Cluster: ${TASK_CONFLICT_CLUSTER[$line]}"
  done
}
