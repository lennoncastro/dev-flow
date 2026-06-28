#!/usr/bin/env bash
set -euo pipefail

# Args: list of file paths touched by the task
# Output: lines of "<scope_path>|<agent_file_path>" (one per specialist)
# Exit 1 if none found.

declare -A seen_scopes  # scope_path -> agent_file (deepest wins)

find_repo_root() {
  local dir="$1"
  while [ "$dir" != "/" ]; do
    [ -d "${dir}/.git" ] && echo "$dir" && return
    dir=$(dirname "$dir")
  done
  echo "/"
}

collect_agents() {
  local path="$1"
  local abs_path
  abs_path=$(realpath -m "$path" 2>/dev/null || echo "$path")

  local dir
  if [ -f "$abs_path" ]; then
    dir=$(dirname "$abs_path")
  else
    dir="$abs_path"
  fi

  local repo_root
  repo_root=$(find_repo_root "$dir")

  while [ "$dir" != "/" ] && [ "${#dir}" -ge "${#repo_root}" ]; do
    local agents_dir="${dir}/.claude/agents"
    if [ -d "$agents_dir" ]; then
      while IFS= read -r -d '' agent_file; do
        local scope="$dir"
        # Most specific (deepest) wins: only record if scope not already seen
        if [ -z "${seen_scopes[$scope]+_}" ]; then
          seen_scopes[$scope]="$agent_file"
        fi
      done < <(find "$agents_dir" -maxdepth 1 -name "*.md" -print0 2>/dev/null)
    fi
    [ "$dir" = "$repo_root" ] && break
    dir=$(dirname "$dir")
  done
}

[ $# -eq 0 ] && { echo "Usage: discover-specialists.sh <path>..." >&2; exit 1; }

for arg in "$@"; do
  collect_agents "$arg"
done

if [ ${#seen_scopes[@]} -eq 0 ]; then
  exit 1
fi

for scope in "${!seen_scopes[@]}"; do
  echo "${scope}|${seen_scopes[$scope]}"
done

exit 0
