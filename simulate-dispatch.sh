#!/usr/bin/env bash
# simulate-dispatch.sh — 🧪 Simulation mode for task dispatch strategies
#
# Tests different routing strategies against a TASKS.md file without burning tokens.
# Outputs comparison metrics: estimated wall-clock time, parallelism efficiency, conflict probability.
#
# Usage:
#   ./simulate-dispatch.sh TASKS.md               # simulate current tasks
#   ./simulate-dispatch.sh TASKS.md --jerries 4   # test with 4 Jerry slots
#   ./simulate-dispatch.sh TASKS.md --verbose     # show detailed routing decisions

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_FILE="${1:-TASKS.md}"
JERRIES=2
VERBOSE=false

# Parse args
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --jerries)
      JERRIES="$2"
      shift 2
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

LOG_FILE="/dev/null"
LOG_PREFIX="[SIMULATE]"
AUTO_MODE=""
MAX_PARALLEL=$JERRIES
PENDING=0

source "$SCRIPT_DIR/lib/house-common.sh"
source "$SCRIPT_DIR/lib/house-dispatch.sh"

# ─── Mock Functions ─────────────────────────────────────────────────────────

house_log() {
  [ "$VERBOSE" = true ] && echo "$*"
}

# ─── Simulation Engine ──────────────────────────────────────────────────────

simulate_fifo_routing() {
  # Simple FIFO: tasks assigned in order, no conflict awareness
  local -a task_lines=("$@")
  local total_time=0
  local tom_time=0
  local jerry_times=()
  for ((i=0; i<JERRIES; i++)); do
    jerry_times[$i]=0
  done

  local next_jerry=0
  local first_task=true

  for line in "${task_lines[@]}"; do
    local est_time=$(get_task_estimated_time "$line")
    est_time="${est_time:-180}"

    if [ "$first_task" = true ]; then
      # Tom gets first task
      tom_time=$est_time
      first_task=false
    else
      # Jerrys get remaining tasks (round-robin)
      jerry_times[$next_jerry]=$((jerry_times[$next_jerry] + est_time))
      next_jerry=$(( (next_jerry + 1) % JERRIES ))
    fi
  done

  # Wall-clock time = max(tom_time, max(jerry_times))
  local max_jerry=0
  for ((i=0; i<JERRIES; i++)); do
    [ "${jerry_times[$i]}" -gt "$max_jerry" ] && max_jerry="${jerry_times[$i]}"
  done

  [ "$tom_time" -gt "$max_jerry" ] && total_time=$tom_time || total_time=$max_jerry

  echo "$total_time"
}

simulate_smart_routing() {
  # Smart routing: heavy → Tom, light → Jerrys (conflict-aware)
  local -a task_lines=("$@")
  local total_time=0
  local tom_time=0
  local jerry_times=()
  for ((i=0; i<JERRIES; i++)); do
    jerry_times[$i]=0
  done

  # Categorize tasks
  local -a heavy=()
  local -a light=()
  for line in "${task_lines[@]}"; do
    local complexity=$(get_task_complexity "$line")
    if [ "$complexity" = "heavy" ]; then
      heavy+=("$line")
    else
      light+=("$line")
    fi
  done

  # Tom handles all heavy tasks (sequential)
  for line in "${heavy[@]}"; do
    local est_time=$(get_task_estimated_time "$line")
    tom_time=$((tom_time + est_time))
  done

  # Jerrys handle light tasks (parallel, conflict-aware)
  local -a assigned_to_jerry=()
  for line in "${light[@]}"; do
    # Find a Jerry slot with no conflict
    local assigned=false
    for ((ji=0; ji<JERRIES; ji++)); do
      local has_conflict=false

      # Check against all tasks already assigned to this Jerry
      for other_line in "${assigned_to_jerry[@]}"; do
        local other_jerry=$(echo "$other_line" | cut -d: -f1)
        [ "$other_jerry" != "$ji" ] && continue

        local other_task=$(echo "$other_line" | cut -d: -f2)
        if ! can_parallelize_with "$line" "$other_task" 2>/dev/null; then
          has_conflict=true
          break
        fi
      done

      if [ "$has_conflict" = false ]; then
        # Assign to this Jerry
        local est_time=$(get_task_estimated_time "$line")
        jerry_times[$ji]=$((jerry_times[$ji] + est_time))
        assigned_to_jerry+=("$ji:$line")
        assigned=true
        break
      fi
    done

    if [ "$assigned" = false ]; then
      # Couldn't parallelize — fallback to Tom
      local est_time=$(get_task_estimated_time "$line")
      tom_time=$((tom_time + est_time))
    fi
  done

  # Wall-clock time = max(tom_time, max(jerry_times))
  local max_jerry=0
  for ((i=0; i<JERRIES; i++)); do
    [ "${jerry_times[$i]}" -gt "$max_jerry" ] && max_jerry="${jerry_times[$i]}"
  done

  [ "$tom_time" -gt "$max_jerry" ] && total_time=$tom_time || total_time=$max_jerry

  echo "$total_time"
}

calculate_metrics() {
  local -a task_lines=("$@")
  local total_tasks=${#task_lines[@]}

  # Count conflict clusters
  local -A clusters
  for line in "${task_lines[@]}"; do
    local cluster=$(get_task_conflict_cluster "$line")
    clusters[$cluster]=1
  done
  local unique_clusters=${#clusters[@]}

  # Theoretical max parallelism (assuming infinite workers)
  local max_parallelism=$unique_clusters

  # Parallelism efficiency with current Jerry count
  local usable_parallelism=$((JERRIES + 1))  # Tom + Jerrys
  [ "$usable_parallelism" -gt "$max_parallelism" ] && usable_parallelism=$max_parallelism

  local efficiency=$(awk "BEGIN {printf \"%.1f\", ($usable_parallelism / ($JERRIES + 1.0)) * 100}")

  # Conflict probability (% of task pairs that can't parallelize)
  local total_pairs=$(( total_tasks * (total_tasks - 1) / 2 ))
  local conflict_pairs=0
  if [ "$total_pairs" -gt 0 ]; then
    for ((i=0; i<total_tasks; i++)); do
      for ((j=i+1; j<total_tasks; j++)); do
        local line_i="${task_lines[$i]}"
        local line_j="${task_lines[$j]}"
        if ! can_parallelize_with "$line_i" "$line_j" 2>/dev/null; then
          conflict_pairs=$((conflict_pairs + 1))
        fi
      done
    done
  fi

  local conflict_pct=0
  [ "$total_pairs" -gt 0 ] && conflict_pct=$(awk "BEGIN {printf \"%.1f\", ($conflict_pairs / $total_pairs) * 100}")

  echo "$efficiency|$conflict_pct|$unique_clusters"
}

# ─── Main Simulation ────────────────────────────────────────────────────────

run_simulation() {
  if [ ! -f "$TASK_FILE" ]; then
    echo "ERROR: Task file '$TASK_FILE' not found."
    exit 1
  fi

  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║  🧪 Task Dispatch Simulation                                  ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  echo "Task file: $TASK_FILE"
  echo "Workers: 1 Tom + $JERRIES Jerrys"
  echo ""

  # Find active section
  local sep_line
  sep_line=$(grep -n '^_{5,}' "$TASK_FILE" 2>/dev/null | head -1 | cut -d: -f1)
  sep_line="${sep_line:-0}"

  if ! find_active_section "$TASK_FILE" "$sep_line"; then
    echo "ERROR: No active section found in $TASK_FILE"
    exit 1
  fi

  # Collect pending tasks
  local -a task_lines=()
  while IFS= read -r candidate; do
    local line_num
    line_num=$(echo "$candidate" | cut -d: -f1)
    [ "$line_num" -lt "$ACTIVE_SECTION_START" ] && continue
    [ "$line_num" -gt "$ACTIVE_SECTION_END" ] && break

    local task_desc
    task_desc=$(echo "$candidate" | sed 's/^[0-9]*:\[ \] //')

    # Skip status lines
    if echo "$task_desc" | grep -qiE '^(pending|done|in progress|failed|waiting)(\s|$)'; then
      continue
    fi

    task_lines+=("$line_num")
  done < <(grep -n '^\[ \] ' "$TASK_FILE" 2>/dev/null || true)

  if [ ${#task_lines[@]} -eq 0 ]; then
    echo "No pending tasks to simulate."
    exit 0
  fi

  echo "Found ${#task_lines[@]} pending task(s) in section '$ACTIVE_SECTION_NAME'"
  echo ""

  # Run pre-flight analysis (this uses Claude)
  echo "🧠 Running pre-flight analysis (this will call Claude once)..."
  if ! analyze_task_batch "$ACTIVE_SECTION_NAME"; then
    echo "ERROR: Analysis failed. Cannot simulate without task metadata."
    exit 1
  fi

  echo ""
  echo "─────────────────────────────────────────────────────────────────"
  echo "📊 SIMULATION RESULTS"
  echo "─────────────────────────────────────────────────────────────────"

  # Calculate metrics
  local metrics
  metrics=$(calculate_metrics "${task_lines[@]}")
  local efficiency
  efficiency=$(echo "$metrics" | cut -d'|' -f1)
  local conflict_pct
  conflict_pct=$(echo "$metrics" | cut -d'|' -f2)
  local clusters
  clusters=$(echo "$metrics" | cut -d'|' -f3)

  echo "Task breakdown:"
  local light=0 medium=0 heavy=0
  for line in "${task_lines[@]}"; do
    case "$(get_task_complexity "$line")" in
      light) light=$((light + 1)) ;;
      medium) medium=$((medium + 1)) ;;
      heavy) heavy=$((heavy + 1)) ;;
    esac
  done
  echo "  - Light: $light"
  echo "  - Medium: $medium"
  echo "  - Heavy: $heavy"
  echo ""

  echo "Conflict analysis:"
  echo "  - Conflict clusters: $clusters"
  echo "  - Conflict probability: ${conflict_pct}%"
  echo "  - Parallelism efficiency: ${efficiency}%"
  echo ""

  # Run simulations
  echo "Simulating FIFO routing (no conflict awareness)..."
  local fifo_time
  fifo_time=$(simulate_fifo_routing "${task_lines[@]}")

  echo "Simulating SMART routing (conflict-aware + prioritization)..."
  local smart_time
  smart_time=$(simulate_smart_routing "${task_lines[@]}")

  echo ""
  echo "─────────────────────────────────────────────────────────────────"
  echo "⏱️  PERFORMANCE COMPARISON"
  echo "─────────────────────────────────────────────────────────────────"

  local fifo_min smart_min
  fifo_min=$(awk "BEGIN {printf \"%.1f\", $fifo_time / 60}")
  smart_min=$(awk "BEGIN {printf \"%.1f\", $smart_time / 60}")

  echo "FIFO routing:  ${fifo_min} minutes (${fifo_time}s)"
  echo "SMART routing: ${smart_min} minutes (${smart_time}s)"
  echo ""

  if [ "$smart_time" -lt "$fifo_time" ]; then
    local speedup savings
    speedup=$(awk "BEGIN {printf \"%.1f\", ($fifo_time - $smart_time) / $fifo_time * 100}")
    savings=$(awk "BEGIN {printf \"%.1f\", ($fifo_time - $smart_time) / 60}")
    echo "✅ Smart routing is FASTER by ${speedup}% (saves ${savings} min)"
  elif [ "$smart_time" -eq "$fifo_time" ]; then
    echo "⚖️  Both strategies perform identically (no parallelism conflicts)"
  else
    local slowdown
    slowdown=$(awk "BEGIN {printf \"%.1f\", ($smart_time - $fifo_time) / $fifo_time * 100}")
    echo "⚠️  Smart routing is slower by ${slowdown}% (heavy task bottleneck)"
  fi

  echo ""
  echo "─────────────────────────────────────────────────────────────────"
  echo "💡 RECOMMENDATIONS"
  echo "─────────────────────────────────────────────────────────────────"

  if (( $(echo "$conflict_pct > 30" | bc -l) )); then
    echo "⚠️  HIGH conflict rate (${conflict_pct}%) — smart routing will prevent merge conflicts"
  elif (( $(echo "$conflict_pct > 10" | bc -l) )); then
    echo "✅ MODERATE conflict rate (${conflict_pct}%) — smart routing recommended"
  else
    echo "✅ LOW conflict rate (${conflict_pct}%) — both strategies work well"
  fi

  if [ "$heavy" -gt "$((JERRIES * 2))" ]; then
    echo "⚠️  Many heavy tasks ($heavy) — consider increasing Jerry count or splitting tasks"
  fi

  if (( $(echo "$efficiency < 70" | bc -l) )); then
    echo "⚠️  Low parallelism efficiency (${efficiency}%) — many tasks share files"
    echo "   Consider: breaking tasks into smaller, more independent units"
  fi

  echo ""
  echo "🧠 Smart routing is now ENABLED in claude-supervisor.sh"
  echo "   To disable: comment out the analyze_task_batch() call in the supervisor"
  echo ""
}

# Run the simulation
run_simulation
