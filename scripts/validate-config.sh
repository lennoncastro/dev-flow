#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-${PWD}/.devflow.yaml}"

fail() {
  echo "DevFlow config error: $1" >&2
  exit 1
}

[ -f "$CONFIG" ] || fail "'.devflow.yaml' not found at '${CONFIG}'"

# --- Read helpers ---
# grep-based: no external dependencies (avoids Python yq vs Go yq conflicts)
yq_get() {
  local key="$1"
  local top="${key%%.*}"
  local rest="${key#*.}"
  if [ "$top" = "$rest" ]; then
    grep -E "^${top}:" "$CONFIG" | awk -F': ' '{print $2}' | tr -d '"' | tr -d "'" | xargs || true
  else
    awk "/^${top}:/{found=1} found && /^  ${rest}:/{print \$2; exit}" "$CONFIG" | tr -d '"' | tr -d "'" | xargs || true
  fi
}

# --- Required fields ---
VERSION=$(yq_get 'version')
[ -n "$VERSION" ] || fail "'version' is required"
[[ "$VERSION" =~ ^[0-9]+$ ]] || fail "'version' must be an integer (got: '${VERSION}')"

BASE_BRANCH=$(yq_get 'base_branch')
[ -n "$BASE_BRANCH" ] || fail "'base_branch' is required and must be non-empty"

MODELS_PLAN=$(yq_get 'models.plan')
[ -n "$MODELS_PLAN" ] || fail "'models.plan' is required"

MODELS_EXEC=$(yq_get 'models.execution')
[ -n "$MODELS_EXEC" ] || fail "'models.execution' is required"

CMD_TEST=$(yq_get 'commands.test')
[ -n "$CMD_TEST" ] || fail "'commands.test' is required"

# --- fan_out ---
FAN_OUT_ENABLED=$(yq_get 'fan_out.enabled')
if [ "$FAN_OUT_ENABLED" = "true" ]; then
  MAX_AGENTS=$(yq_get 'fan_out.max_agents')
  if [ -n "$MAX_AGENTS" ]; then
    if ! { [[ "$MAX_AGENTS" =~ ^[0-9]+$ ]] && [ "$MAX_AGENTS" -ge 1 ]; }; then
      fail "'fan_out.max_agents' must be >= 1 when fan_out is enabled (got: '${MAX_AGENTS}')"
    fi
  fi

  ON_PARTIAL=$(yq_get 'fan_out.on_partial_failure')
  if [ -n "$ON_PARTIAL" ]; then
    case "$ON_PARTIAL" in
      abort|isolate|retry) ;;
      *) fail "'fan_out.on_partial_failure' must be one of: abort, isolate, retry (got: '${ON_PARTIAL}')" ;;
    esac
    if [ "$ON_PARTIAL" = "retry" ]; then
      RETRY_LIMIT=$(yq_get 'fan_out.retry_limit')
      if ! { [ -n "$RETRY_LIMIT" ] && [[ "$RETRY_LIMIT" =~ ^[0-9]+$ ]] && [ "$RETRY_LIMIT" -ge 1 ]; }; then
        fail "'fan_out.retry_limit' must be >= 1 when on_partial_failure is 'retry' (got: '${RETRY_LIMIT}')"
      fi
    fi
  fi
fi

# --- fallback ---
FALLBACK_MODE=$(yq_get 'fallback.mode')
if [ -n "$FALLBACK_MODE" ]; then
  case "$FALLBACK_MODE" in
    generic|refuse) ;;
    *) fail "'fallback.mode' must be one of: generic, refuse (got: '${FALLBACK_MODE}')" ;;
  esac
  if [ "$FALLBACK_MODE" = "generic" ]; then
    GENERIC_AGENT=$(yq_get 'fallback.generic_agent')
    if [ -n "$GENERIC_AGENT" ]; then
      [ -f "$GENERIC_AGENT" ] || fail "'fallback.generic_agent' points to non-existent file: '${GENERIC_AGENT}'"
    fi
  fi
fi

# --- spec ---
SPEC_REQUIRE=$(yq_get 'spec.require_approved')
if [ "$SPEC_REQUIRE" = "true" ]; then
  SPEC_TOOL=$(yq_get 'spec.tool')
  [ -n "$SPEC_TOOL" ] || fail "'spec.require_approved: true' requires 'spec.tool' to be set"
fi

# --- limits ---
LIMITS_ON_LIMIT=$(yq_get 'limits.on_limit')
if [ -n "$LIMITS_ON_LIMIT" ]; then
  case "$LIMITS_ON_LIMIT" in
    confirm|abort) ;;
    *) fail "'limits.on_limit' must be one of: confirm, abort (got: '${LIMITS_ON_LIMIT}')" ;;
  esac
fi

echo "DevFlow: config valid (version=${VERSION}, base_branch=${BASE_BRANCH})"
exit 0
