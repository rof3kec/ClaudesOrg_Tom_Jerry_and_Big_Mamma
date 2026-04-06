#!/usr/bin/env bash
# lib/house-git.sh — Git operations for Big Mamma
#
# Sourced by claude-supervisor.sh. Requires house-common.sh loaded first.
#
# Globals read:  BRANCH, VERBOSE_LOG, PUSH_PENDING, MERGED_TO_MAIN
# Globals write: PUSH_PENDING, MERGED_TO_MAIN

# Guard against double-sourcing
[[ -n "${_HOUSE_GIT_LOADED:-}" ]] && return 0
_HOUSE_GIT_LOADED=1

# ─── Push with fallback strategies ──────────────────────────────────────────

push_changes() {
  house_log "👩🏽📤 Big Mamma: Sending this out the door to origin/$BRANCH..."

  if git push origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
    house_log "👩🏽✓ Out the DOOR! Pushed to origin/$BRANCH"
    return 0
  fi

  house_log "👩🏽⚠ Door's stuck! Trying the back door... (pull --rebase)"
  if git pull --rebase origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
    if git push origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
      house_log "👩🏽✓ Got it out the back door! Pushed after rebase."
      return 0
    fi
  fi
  git rebase --abort >> "$VERBOSE_LOG" 2>&1 || true

  house_log "👩🏽⚠ Back door's stuck too! Trying the WINDOW... (merge)"
  if git pull --no-rebase origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
    if git push origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
      house_log "👩🏽✓ Shoved it through the window! Pushed after merge."
      return 0
    fi
  fi

  house_log "👩🏽⚠ Lord have MERCY... getting the BATTERING RAM (force-with-lease)"
  if git push --force-with-lease origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
    house_log "👩🏽✓ BOOM! Door's DOWN! Force-pushed (with lease) to origin/$BRANCH"
    return 0
  fi

  house_log "👩🏽✗ Can't get this out the door no-HOW. Will try again next cycle."
  PUSH_PENDING=true
  return 1
}

# ─── Merge to main ──────────────────────────────────────────────────────────

merge_to_main() {
  house_log "👩🏽🚀 ALL tasks done! Big Mamma's moving this to the MAIN STAGE!"
  house_log "   Merging $BRANCH into main..."

  if ! git push origin "$BRANCH" >> "$VERBOSE_LOG" 2>&1; then
    house_log "👩🏽⚠ Couldn't push $BRANCH before merge. Trying anyway..."
  fi

  if ! git fetch origin main >> "$VERBOSE_LOG" 2>&1; then
    house_log "👩🏽✗ Couldn't fetch main. Merge CANCELLED. I am NOT happy."
    return 1
  fi

  if ! git checkout main >> "$VERBOSE_LOG" 2>&1; then
    house_log "👩🏽✗ Couldn't checkout main. Merge CANCELLED."
    git checkout "$BRANCH" >> "$VERBOSE_LOG" 2>&1 || true
    return 1
  fi

  git pull origin main >> "$VERBOSE_LOG" 2>&1 || true

  if git merge "$BRANCH" -m "merge: $BRANCH into main (all tasks completed)" >> "$VERBOSE_LOG" 2>&1; then
    house_log "👩🏽✓ Merged $BRANCH into main! *chef's kiss*"
    if git push origin main >> "$VERBOSE_LOG" 2>&1; then
      house_log "👩🏽✓ Main is LIVE! Pushed to origin. Big Mamma is PROUD!"
      MERGED_TO_MAIN=true
    else
      house_log "👩🏽✗ Merged locally but couldn't push main. Push it yourself, child."
    fi
  else
    house_log "👩🏽✗ MERGE CONFLICT! Lord have mercy!"
    house_log "   \"I swear, y'all can't do NOTHING right without me!\""
    git merge --abort >> "$VERBOSE_LOG" 2>&1 || true
  fi

  git checkout "$BRANCH" >> "$VERBOSE_LOG" 2>&1 || true
}
