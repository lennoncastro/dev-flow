---
name: devflow
description: DevFlow motor — AI-assisted development workflow. Usage: /devflow start <task> | /devflow status
---

Parse the first word of $ARGUMENTS as the subcommand. Everything after is the subcommand's arguments.

```bash
SUBCMD=$(echo "$ARGUMENTS" | awk '{print $1}')
SUBARGS=$(echo "$ARGUMENTS" | cut -d' ' -f2-)
```

---

## Subcommand: start

Triggered when `$SUBCMD = start`. Task description is `$SUBARGS`.

Execute the DevFlow workflow for the task described in `$SUBARGS`.

You are the DevFlow motor. Follow every step below in order. Never operate directly on the base branch. Never skip a gate. Never hardcode any stack, model, or command.

### Step 1 — Validate config

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/validate-config.sh" "${PWD}/.devflow.yaml"
```

If it exits non-zero, stop immediately and show the error. Do not proceed.

### Step 2 — Read config

```bash
BASE_BRANCH=$(yq e '.base_branch' .devflow.yaml 2>/dev/null || grep -E '^base_branch:' .devflow.yaml | awk '{print $2}')
MODEL_PLAN=$(yq e '.models.plan' .devflow.yaml 2>/dev/null || grep -A2 '^models:' .devflow.yaml | grep 'plan:' | awk '{print $2}')
MODEL_EXEC=$(yq e '.models.execution' .devflow.yaml 2>/dev/null || grep -A3 '^models:' .devflow.yaml | grep 'execution:' | awk '{print $2}')
CMD_TEST=$(yq e '.commands.test // ""' .devflow.yaml 2>/dev/null || true)
CMD_LINT=$(yq e '.commands.lint // ""' .devflow.yaml 2>/dev/null || true)
CMD_BUILD=$(yq e '.commands.build // ""' .devflow.yaml 2>/dev/null || true)
CMD_DEPLOY=$(yq e '.commands.deploy // ""' .devflow.yaml 2>/dev/null || true)
FAN_OUT_ENABLED=$(yq e '.fan_out.enabled // "false"' .devflow.yaml 2>/dev/null || echo "false")
MAX_AGENTS=$(yq e '.fan_out.max_agents // "1"' .devflow.yaml 2>/dev/null || echo "1")
ON_PARTIAL=$(yq e '.fan_out.on_partial_failure // "abort"' .devflow.yaml 2>/dev/null || echo "abort")
GATE_TESTS=$(yq e '.gates.require_tests_pass // "true"' .devflow.yaml 2>/dev/null || echo "true")
GATE_LINT=$(yq e '.gates.require_lint_pass // "true"' .devflow.yaml 2>/dev/null || echo "true")
DEPLOY_BEFORE_PR=$(yq e '.gates.deploy_before_pr // "false"' .devflow.yaml 2>/dev/null || echo "false")
FALLBACK_MODE=$(yq e '.fallback.mode // "generic"' .devflow.yaml 2>/dev/null || echo "generic")
```

### Step 3 — Generate task slug and run ID

```bash
TASK_SLUG=$(echo "$SUBARGS" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-*$//' | cut -c1-40)
RUN_ID="${TASK_SLUG}-$(date +%s)"
REPO_ROOT=$(git rev-parse --show-toplevel)
```

### Step 4 — Start telemetry

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" start "$RUN_ID" "task=$SUBARGS" "base_branch=$BASE_BRANCH"
```

### Step 5 — Create worktree

```bash
WORKTREE=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-create.sh" "$TASK_SLUG" "$BASE_BRANCH" "$REPO_ROOT")
```

If it exits non-zero, stop and show the error. All subsequent file operations happen inside `$WORKTREE`.

### Step 6 — Plan

Using model `$MODEL_PLAN`, produce a structured plan for the task. Identify:
- Which files/directories will be touched
- Scopes (for specialist discovery and fan-out)
- Sub-tasks that can be parallelized

Record touched paths in `$TOUCHED_PATHS` (space-separated).

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=plan" "status=done"
```

### Step 7 — Discover specialists

```bash
SPECIALISTS=$("${CLAUDE_PLUGIN_ROOT}/scripts/discover-specialists.sh" $TOUCHED_PATHS 2>/dev/null || true)
```

If `$SPECIALISTS` is empty:
- `FALLBACK_MODE=refuse` → stop, ask user to create a specialist in `.claude/agents/`
- `FALLBACK_MODE=generic` → use `"${CLAUDE_PLUGIN_ROOT}/agents/generic.md"`

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=discover" "specialists_found=$(echo "$SPECIALISTS" | grep -c '|' || echo 0)"
```

### Step 8 — Fan-out execution

Spawn specialist agents to implement the plan. Respect `$MAX_AGENTS`. Each specialist works exclusively in its scope within `$WORKTREE`. Specialists must not open PRs, manage git, or run tests.

Handle `$ON_PARTIAL`:
- `abort` → any failure cancels the run
- `isolate` → continue with passing scopes, mark failures in telemetry
- `retry` → re-run failed agents up to `retry_limit` before abort

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=execute" "status=done"
```

### Step 9 — Test gate

If `$CMD_TEST` is set, run it inside `$WORKTREE`. If it fails and `$GATE_TESTS=true`, log and stop.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=test" "status=passed"
```

### Step 10 — Lint gate

If `$CMD_LINT` is set, run it inside `$WORKTREE`. If it fails and `$GATE_LINT=true`, log and stop.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=lint" "status=passed"
```

### Step 11 — Build (optional)

If `$CMD_BUILD` is set, run it inside `$WORKTREE`.

### Step 12 — Review

Self-review all changes in `$WORKTREE`: correctness vs plan, no hardcoded values, no regressions, adequate test coverage. If issues found, return to Step 8 for targeted re-execution.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=review" "status=passed"
```

### Step 13 — Pre-PR deploy (optional)

If `$CMD_DEPLOY` is set and `$DEPLOY_BEFORE_PR=true`, run deploy inside `$WORKTREE`.

### Step 14 — Commit and open PR

```bash
cd "$WORKTREE"
git add -A
git commit -m "feat: $SUBARGS"
git push origin "devflow/$TASK_SLUG"
gh pr create --title "feat: $SUBARGS" --body "Automated by DevFlow run \`$RUN_ID\`." --base "$BASE_BRANCH"
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=pr" "status=opened"
```

### Step 15 — Post-PR deploy (optional)

If `$CMD_DEPLOY` is set and `$DEPLOY_BEFORE_PR=false`, run deploy after PR.

### Step 16 — Cleanup

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/worktree-cleanup.sh" "$TASK_SLUG"
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" stop "$RUN_ID" "status=success"
```

Report the PR URL and a summary of phases completed.

---

## Subcommand: status

Triggered when `$SUBCMD = status`.

Show the status of all DevFlow runs in this repository.

```bash
TELEMETRY_DIR=".devflow/runs"
if [ -f ".devflow.yaml" ]; then
  CONFIGURED=$(yq e '.telemetry.path // ""' .devflow.yaml 2>/dev/null || \
    grep -E '^  path:' .devflow.yaml | awk '{print $2}' | tr -d '"' | tr -d "'" || true)
  [ -n "$CONFIGURED" ] && TELEMETRY_DIR="$CONFIGURED"
fi

if [ ! -d "$TELEMETRY_DIR" ] || [ -z "$(ls -A "$TELEMETRY_DIR" 2>/dev/null)" ]; then
  echo "No DevFlow runs found in ${TELEMETRY_DIR}."
  exit 0
fi

for file in "$TELEMETRY_DIR"/*.jsonl; do
  run_id=$(basename "$file" .jsonl)
  last_event=$(tail -1 "$file")
  event=$(echo "$last_event" | jq -r '.event // "unknown"')
  ts=$(echo "$last_event" | jq -r '.ts // "unknown"')
  status=$(echo "$last_event" | jq -r '.status // "-"')
  echo "Run: ${run_id} | Last event: ${event} | Status: ${status} | At: ${ts}"
done
```

---

## Unknown subcommand

If `$SUBCMD` is not `start` or `status`, respond:

```
DevFlow: unknown subcommand '$SUBCMD'. Usage:
  /devflow start <task description>
  /devflow status
```
