#!/usr/bin/env bash
set -euo pipefail

# Args: <task-id> <base_branch> <repo_root>
TASK_ID="${1:?task-id required}"
BASE_BRANCH="${2:?base_branch required}"
REPO_ROOT="${3:?repo_root required}"

WORKTREE_PATH="${REPO_ROOT}/.devflow/worktrees/${TASK_ID}"
BRANCH_NAME="devflow/${TASK_ID}"

# Idempotent: return existing path if already present
if git -C "$REPO_ROOT" worktree list --porcelain | grep -q "^worktree ${WORKTREE_PATH}$"; then
  echo "$WORKTREE_PATH"
  exit 0
fi

# Verify remote base_branch exists
git -C "$REPO_ROOT" fetch origin "$BASE_BRANCH" 2>/dev/null || {
  echo "DevFlow: base_branch '${BASE_BRANCH}' not found on remote 'origin'" >&2
  exit 1
}

mkdir -p "${REPO_ROOT}/.devflow/worktrees"

# If branch already exists locally (e.g. from a previous interrupted run), reuse it
if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${BRANCH_NAME}"; then
  git -C "$REPO_ROOT" worktree add "$WORKTREE_PATH" "$BRANCH_NAME"
else
  git -C "$REPO_ROOT" worktree add "$WORKTREE_PATH" -b "$BRANCH_NAME" "origin/${BASE_BRANCH}"
fi

echo "$WORKTREE_PATH"
exit 0
