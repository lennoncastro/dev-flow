#!/usr/bin/env bash
# Telemetry must never break the workflow — all failures are silently swallowed.
set -uo pipefail

EVENT="${1:-unknown}"
RUN_ID="${2:-unknown}"
shift 2 2>/dev/null || true

# Resolve telemetry path from config or use default
CONFIG="${PWD}/.devflow.yaml"
TELEMETRY_PATH=".devflow/runs"
if [ -f "$CONFIG" ]; then
  if command -v yq &>/dev/null; then
    CONFIGURED=$(yq e '.telemetry.path // ""' "$CONFIG" 2>/dev/null || true)
  else
    CONFIGURED=$(grep -E '^  path:' "$CONFIG" | awk '{print $2}' | tr -d '"' | tr -d "'" || true)
  fi
  [ -n "$CONFIGURED" ] && TELEMETRY_PATH="$CONFIGURED"
fi

mkdir -p "$TELEMETRY_PATH" 2>/dev/null || exit 0

JSONL_FILE="${TELEMETRY_PATH}/${RUN_ID}.jsonl"
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build extra key=value pairs as JSON fields
EXTRA_JSON=""
for pair in "$@"; do
  key="${pair%%=*}"
  val="${pair#*=}"
  EXTRA_JSON="${EXTRA_JSON},\"${key}\":\"${val}\""
done

printf '{"ts":"%s","event":"%s","run_id":"%s"%s}\n' \
  "$TS" "$EVENT" "$RUN_ID" "$EXTRA_JSON" >> "$JSONL_FILE" 2>/dev/null || true

exit 0
