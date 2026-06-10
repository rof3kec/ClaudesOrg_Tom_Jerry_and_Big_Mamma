#!/usr/bin/env bash
# lib/house-ai.sh — AI provider & model config for The House
#
# Loaded automatically by house-common.sh (SCRIPT_DIR must be set by caller).
# Exposes: get_ai_cmd ROLE [AUTO_MODE]
#
# ROLE:      planner | worker | jerry | qa
# AUTO_MODE: --auto  (enables skip-permissions for Claude only)
#
# Config file: $SCRIPT_DIR/house-model.conf  (KEY=VALUE, editable via dashboard)

[[ -n "${_HOUSE_AI_LOADED:-}" ]] && return 0
_HOUSE_AI_LOADED=1

# ─── Internal config state (prefixed to avoid collisions) ────────────────────

_HAI_PROVIDER="claude"
_HAI_PLANNER_MODEL=""
_HAI_WORKER_MODEL=""
_HAI_JERRY_MODEL=""
_HAI_QA_MODEL=""
_HAI_API_KEY=""
_HAI_BASE_URL=""

# ─── Load house-model.conf ───────────────────────────────────────────────────

_HAI_CONF="${SCRIPT_DIR}/house-model.conf"

if [ -f "$_HAI_CONF" ]; then
  while IFS= read -r _hai_line || [ -n "$_hai_line" ]; do
    [[ "$_hai_line" =~ ^[[:space:]]*# ]]  && continue
    [[ "$_hai_line" =~ ^[[:space:]]*$ ]]  && continue
    _hai_k="${_hai_line%%=*}"
    _hai_v="${_hai_line#*=}"
    _hai_k="${_hai_k//[[:space:]]/}"
    _hai_v="${_hai_v#"${_hai_v%%[![:space:]]*}"}"
    _hai_v="${_hai_v%"${_hai_v##*[![:space:]]}"}"
    case "$_hai_k" in
      HOUSE_PROVIDER)      _HAI_PROVIDER="$_hai_v" ;;
      HOUSE_PLANNER_MODEL) _HAI_PLANNER_MODEL="$_hai_v" ;;
      HOUSE_WORKER_MODEL)  _HAI_WORKER_MODEL="$_hai_v" ;;
      HOUSE_JERRY_MODEL)   _HAI_JERRY_MODEL="$_hai_v" ;;
      HOUSE_QA_MODEL)      _HAI_QA_MODEL="$_hai_v" ;;
      HOUSE_API_KEY)       _HAI_API_KEY="$_hai_v" ;;
      HOUSE_BASE_URL)      _HAI_BASE_URL="$_hai_v" ;;
    esac
  done < "$_HAI_CONF"
fi

# ─── Inject credentials into environment ─────────────────────────────────────

if [ -n "$_HAI_API_KEY" ]; then
  case "$_HAI_PROVIDER" in
    claude) export ANTHROPIC_API_KEY="$_HAI_API_KEY" ;;
    gemini) export GEMINI_API_KEY="$_HAI_API_KEY" ;;
    openai) export OPENAI_API_KEY="$_HAI_API_KEY" ;;
  esac
fi

if [ -n "$_HAI_BASE_URL" ]; then
  case "$_HAI_PROVIDER" in
    claude) export ANTHROPIC_BASE_URL="$_HAI_BASE_URL" ;;
    openai) export OPENAI_BASE_URL="$_HAI_BASE_URL" ;;
  esac
fi

# ─── Command builder ─────────────────────────────────────────────────────────
#
# Usage: cmd=$(get_ai_cmd ROLE [AUTO_MODE])
# Then:  $cmd "task description here" >> log 2>&1 &
#
# The task prompt is always appended as the last argument by the caller.

get_ai_cmd() {
  local role="${1:-worker}"
  local auto_mode="${2:-}"

  local model=""
  case "$role" in
    planner) model="$_HAI_PLANNER_MODEL" ;;
    worker)  model="$_HAI_WORKER_MODEL" ;;
    jerry)   model="$_HAI_JERRY_MODEL" ;;
    qa)      model="$_HAI_QA_MODEL" ;;
  esac

  local cmd=""
  case "$_HAI_PROVIDER" in
    claude)
      cmd="claude -p"
      [ -n "$model" ] && cmd="$cmd --model $model"
      [ "$auto_mode" = "--auto" ] && cmd="$cmd --dangerously-skip-permissions"
      ;;
    gemini)
      # Google Gemini CLI: gemini [--model MODEL] "prompt"
      cmd="gemini"
      [ -n "$model" ] && cmd="$cmd --model $model"
      ;;
    openai)
      # OpenAI-compatible CLI: openai [--model MODEL] "prompt"
      cmd="openai"
      [ -n "$model" ] && cmd="$cmd --model $model"
      ;;
    *)
      # Unknown provider — fall back to Claude
      cmd="claude -p"
      [ "$auto_mode" = "--auto" ] && cmd="$cmd --dangerously-skip-permissions"
      ;;
  esac

  printf '%s' "$cmd"
}

# ─── Summary line (for startup logs) ─────────────────────────────────────────

get_ai_summary() {
  local planner="${_HAI_PLANNER_MODEL:-default}"
  local worker="${_HAI_WORKER_MODEL:-default}"
  local jerry="${_HAI_JERRY_MODEL:-default}"
  local qa="${_HAI_QA_MODEL:-default}"
  printf 'provider=%s planner=%s worker=%s jerry=%s qa=%s' \
    "$_HAI_PROVIDER" "$planner" "$worker" "$jerry" "$qa"
}
