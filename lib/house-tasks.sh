#!/usr/bin/env bash
# lib/house-tasks.sh — Task state management for Big Mamma
#
# Sourced by claude-supervisor.sh. Requires house-common.sh loaded first.
#
# Globals read:  TASK_FILE, VERBOSE_LOG, RETRY_MAX, WORKER_HIBERNATING,
#                MAX_PARALLEL, P_ACTIVE[], P_TASK_LINES[],
#                WSTAT_TASK_LINE, WSTAT_STATE, WSTAT_WORKER_PID,
#                IN_PROGRESS, QA_VALIDATED_DONE
# Globals write: _COUNT_DONE, _COUNT_IP, _COUNT_PENDING, _COUNT_FAILED, _COUNT_QA,
#                WORKER_HIBERNATING, RETRIED_TASKS, ALL_DONE_LOGGED,
#                LAST_DONE_COUNT, PENDING_COMMIT, LAST_CHANGE_TIME, PUSH_PENDING

# Guard against double-sourcing
[[ -n "${_HOUSE_TASKS_LOADED:-}" ]] && return 0
_HOUSE_TASKS_LOADED=1

# ─── Task Counters ────────────────────────────────────────────────────────────
# Single-pass counting to minimize fork overhead (expensive on Windows/MSYS2)

_update_task_counts() {
  _COUNT_DONE=0 _COUNT_IP=0 _COUNT_PENDING=0 _COUNT_FAILED=0 _COUNT_QA=0
  while IFS= read -r line; do
    case "$line" in
      "[x] "*) _COUNT_DONE=$((_COUNT_DONE + 1)) ;;
      "[!] "*) _COUNT_IP=$((_COUNT_IP + 1)) ;;
      "[ ] "*) _COUNT_PENDING=$((_COUNT_PENDING + 1)) ;;
      "[-] "*) _COUNT_FAILED=$((_COUNT_FAILED + 1)) ;;
      "[q] "*) _COUNT_QA=$((_COUNT_QA + 1)) ;;
    esac
  done < "$TASK_FILE" 2>/dev/null
}

count_done() {
  _update_task_counts
  echo "$_COUNT_DONE"
}

count_in_progress() {
  _update_task_counts
  echo "$_COUNT_IP"
}

count_pending() {
  _update_task_counts
  echo "$_COUNT_PENDING"
}

count_failed() {
  _update_task_counts
  echo "$_COUNT_FAILED"
}

count_qa_ready() {
  _update_task_counts
  echo "$_COUNT_QA"
}

# ─── Git Change Detection ───────────────────────────────────────────────────

has_changes() {
  ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]
}

get_recent_done_tasks() {
  local count="${1:-1}"
  grep '^\[x\] ' "$TASK_FILE" | tail -"$count" | sed 's/^\[x\] //' | head -c 500
}

# ─── Stale Task Recovery ────────────────────────────────────────────────────

recover_stale_tasks() {
  lock_tasks
  local stale_count
  stale_count=$(count_in_progress)
  if [ "$stale_count" -eq 0 ]; then
    unlock_tasks
    return 1
  fi

  # Collect active Jerry task lines to exclude from recovery
  local exclude_lines=""
  local exclude_count=0
  for ((i=0; i<MAX_PARALLEL; i++)); do
    if [ "${P_ACTIVE[$i]}" = true ] && [ -n "${P_TASK_LINES[$i]}" ]; then
      local ptask
      ptask=$(sed -n "${P_TASK_LINES[$i]}p" "$TASK_FILE" 2>/dev/null)
      if echo "$ptask" | grep -q '^\[!\] '; then
        exclude_lines="${exclude_lines:+$exclude_lines,}${P_TASK_LINES[$i]}"
        exclude_count=$((exclude_count + 1))
        stale_count=$((stale_count - 1))
      fi
    fi
  done

  # Also exclude Tom's active task if he's alive
  if read_worker_status && [ -n "$WSTAT_TASK_LINE" ] && [ "$WSTAT_STATE" = "running" ]; then
    local tom_pid="${WSTAT_WORKER_PID:-}"
    if [ -n "$tom_pid" ] && is_process_alive "$tom_pid"; then
      exclude_lines="${exclude_lines:+$exclude_lines,}${WSTAT_TASK_LINE}"
      exclude_count=$((exclude_count + 1))
      stale_count=$((stale_count - 1))
    fi
  fi

  if [ "$stale_count" -eq 0 ]; then
    unlock_tasks
    return 1
  fi

  if [ -n "$exclude_lines" ]; then
    # Build awk exclusion — skip Jerry's tasks
    local awk_cond=""
    IFS=',' read -ra EXCL <<< "$exclude_lines"
    for el in "${EXCL[@]}"; do
      awk_cond="${awk_cond:+$awk_cond || }NR==$el"
    done
    awk "($awk_cond){print; next} /^\\[!\\] /{sub(/^\\[!\\] /,\"[ ] \")} {print}" \
      "$TASK_FILE" > "$TASK_FILE.tmp" && mv "$TASK_FILE.tmp" "$TASK_FILE"
    unlock_tasks
    house_log "👩🏽😤 THOMAS! $stale_count task(s) stuck at [!]! Resetting them. (Kept $exclude_count Jerry task(s))"
    return 0
  fi

  house_log "👩🏽😤 THOMAS!! You fell ASLEEP with $stale_count task(s) in your MOUTH!"
  house_log "   Lord have mercy... resetting them to [ ] so you can TRY AGAIN."
  sedi 's/^\[!\] /[ ] /' "$TASK_FILE"
  unlock_tasks
  house_log "   Mm-hmm. Tom will pick them up on next cycle. He BETTER."
  return 0
}

# ─── Cleanup Completed Tasks ────────────────────────────────────────────────

cleanup_done_tasks() {
  # Only safe when nobody's holding line-number references
  if [ "$IN_PROGRESS" -gt 0 ] || any_parallel_active; then
    return
  fi

  # Only remove tasks Spike has validated (fence)
  local max_remove="${QA_VALIDATED_DONE:-0}"
  [ "$max_remove" -gt 0 ] || return

  lock_tasks
  local done_count
  done_count=$(grep -c '^\[x\] ' "$TASK_FILE" 2>/dev/null) || true
  done_count="${done_count:-0}"

  if [ "$done_count" -eq 0 ]; then
    unlock_tasks
    return
  fi

  # Cap at what Spike validated — unvalidated [x] tasks stay
  local to_remove=$done_count
  [ "$to_remove" -gt "$max_remove" ] && to_remove=$max_remove

  house_log "👩🏽🧹 Big Mamma's tidying the task list: $to_remove/$done_count done task(s) (Spike validated: $max_remove)"

  # Remove first N [x] lines + their continuation lines
  awk -v n="$to_remove" '
    /^\[x\] / && removed < n { removed++; skipping=1; next }
    skipping && !/^\[[ xX!-]\] / && !/^#/ && !/^_{5,}/ && NF { next }
    { skipping=0; print }
  ' "$TASK_FILE" > "$TASK_FILE.tmp" && mv "$TASK_FILE.tmp" "$TASK_FILE"

  # Collapse 3+ consecutive blank lines -> 2
  awk 'NF{c=0;print;next} {c++} c<=2{print}' "$TASK_FILE" > "$TASK_FILE.tmp" && mv "$TASK_FILE.tmp" "$TASK_FILE"

  unlock_tasks

  # Commit and push the cleanup
  git add "$TASK_FILE" 2>/dev/null
  git commit -m "auto: cleaned $to_remove completed tasks from $TASK_FILE" >> "$VERBOSE_LOG" 2>&1 || true
  push_changes || true

  # Reset counter since lines are gone
  LAST_DONE_COUNT=$(count_done)

  house_log "   👩🏽✓ House is tidy. That's how we DO things around here."
}

# ─── Retry Failed Tasks ───────────────────────────────────────────────────

retry_failed_tasks() {
  # Only retry when no pending/in-progress tasks remain and retries are allowed
  [ "$PENDING" -eq 0 ] && [ "$IN_PROGRESS" -eq 0 ] || return 1
  [ "$FAILED" -gt 0 ] || return 1

  local retried=0
  lock_tasks

  # Read each [-] line, hash its content, check if already retried
  local tmpfile="$TASK_FILE.retry.tmp"
  while IFS= read -r line; do
    if echo "$line" | grep -q '^\[-\] '; then
      local task_content
      task_content=$(echo "$line" | sed 's/^\[-\] //')
      local task_hash
      task_hash=$(echo "$task_content" | cksum | cut -d' ' -f1)

      if echo "$RETRIED_TASKS" | grep -qw "$task_hash"; then
        # Already retried this task — leave it as failed
        echo "$line"
      else
        # Retry: change [-] back to [ ]
        echo "[ ] $task_content"
        RETRIED_TASKS="${RETRIED_TASKS:+$RETRIED_TASKS }$task_hash"
        retried=$((retried + 1))
      fi
    else
      echo "$line"
    fi
  done < "$TASK_FILE" > "$tmpfile"

  if [ "$retried" -gt 0 ]; then
    mv "$tmpfile" "$TASK_FILE"
    unlock_tasks
    house_log "👩🏽🔄 Big Mamma recycled $retried failed task(s) for ONE more try."
    house_log "   \"Everybody deserves a second chance... but NOT a third.\""
    wake_worker
    ALL_DONE_LOGGED=false
    return 0
  else
    rm -f "$tmpfile"
    unlock_tasks
    return 1
  fi
}

# ─── Hibernation Control ────────────────────────────────────────────────────

hibernate_worker() {
  if [ "$WORKER_HIBERNATING" = false ]; then
    echo "HIBERNATE" > "$HIBERNATE_FILE"
    WORKER_HIBERNATING=true
    house_log "👩🏽 Alright Tom, you can rest now... but I got my EYE on you. 🐱💤"
  fi
}

wake_worker() {
  if [ "$WORKER_HIBERNATING" = true ]; then
    rm -f "$HIBERNATE_FILE"
    WORKER_HIBERNATING=false
    house_log "👩🏽📢 TOM! Get UP! There's work to do, you LAZY cat! 🐱⏰"
  fi
}
