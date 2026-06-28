#!/usr/bin/env bash
set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Only inspect git commands
if ! echo "$COMMAND" | grep -qE '^\s*git\s'; then
  exit 0
fi

# Read base_branch from config if present
CONFIG="${PWD}/.devflow.yaml"
BASE_BRANCH=""
if [ -f "$CONFIG" ]; then
  if command -v yq &>/dev/null; then
    BASE_BRANCH=$(yq e '.base_branch // ""' "$CONFIG" 2>/dev/null || true)
  else
    BASE_BRANCH=$(grep -E '^base_branch:' "$CONFIG" | awk '{print $2}' | tr -d '"' | tr -d "'" || true)
  fi
fi

[ -z "$BASE_BRANCH" ] && exit 0

# Block direct push/commit/merge onto base_branch
if echo "$COMMAND" | grep -qE "git\s+(push|commit|merge|reset|rebase).*\b${BASE_BRANCH}\b"; then
  echo "DevFlow: never operate directly on base_branch '${BASE_BRANCH}'. Use worktree." >&2
  exit 2
fi

# Block committing while currently on base_branch
CURRENT_BRANCH=$(git -C "${PWD}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
if [ "$CURRENT_BRANCH" = "$BASE_BRANCH" ] && echo "$COMMAND" | grep -qE 'git\s+commit'; then
  echo "DevFlow: never operate directly on base_branch '${BASE_BRANCH}'. Use worktree." >&2
  exit 2
fi

exit 0
