#!/usr/bin/env bash
set -euo pipefail

# Args: <task-id> | "all"
TARGET="${1:?task-id or 'all' required}"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")

cleanup_worktree() {
  local task_id="$1"
  local path="${REPO_ROOT}/.devflow/worktrees/${task_id}"
  local branch="devflow/${task_id}"

  if git -C "$REPO_ROOT" worktree list --porcelain | grep -q "^worktree ${path}$"; then
    git -C "$REPO_ROOT" worktree remove --force "$path" 2>/dev/null && echo "Removed worktree: ${path}"
  fi

  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${branch}"; then
    if git -C "$REPO_ROOT" branch -d "$branch" 2>/dev/null || git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null; then
      echo "Deleted branch: ${branch}"
    fi
  fi
}

if [ "$TARGET" = "all" ]; then
  DEVFLOW_WORKTREES_DIR="${REPO_ROOT}/.devflow/worktrees"
  if [ -d "$DEVFLOW_WORKTREES_DIR" ]; then
    for wt_path in "${DEVFLOW_WORKTREES_DIR}"/*/; do
      [ -d "$wt_path" ] || continue
      task_id=$(basename "$wt_path")
      cleanup_worktree "$task_id"
    done
  fi
  # Also prune stale worktree refs
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
else
  cleanup_worktree "$TARGET"
fi

exit 0
