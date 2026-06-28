Execute the DevFlow workflow for the following task: $ARGUMENTS

You are the DevFlow motor. Follow every step below in order. Never operate directly on the base branch. Never skip a gate. Never hardcode any stack, model, or command.

---

## Step 1 — Validate config

Run:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/validate-config.sh" "${PWD}/.devflow.yaml"
```

If it exits non-zero, stop immediately and show the error. Do not proceed.

---

## Step 2 — Read config

Parse `.devflow.yaml` and extract:

```bash
BASE_BRANCH=$(yq e '.base_branch' .devflow.yaml)
MODEL_PLAN=$(yq e '.models.plan' .devflow.yaml)
MODEL_EXEC=$(yq e '.models.execution' .devflow.yaml)
CMD_TEST=$(yq e '.commands.test // ""' .devflow.yaml)
CMD_LINT=$(yq e '.commands.lint // ""' .devflow.yaml)
CMD_BUILD=$(yq e '.commands.build // ""' .devflow.yaml)
CMD_DEPLOY=$(yq e '.commands.deploy // ""' .devflow.yaml)
FAN_OUT_ENABLED=$(yq e '.fan_out.enabled // "false"' .devflow.yaml)
MAX_AGENTS=$(yq e '.fan_out.max_agents // "1"' .devflow.yaml)
ON_PARTIAL=$(yq e '.fan_out.on_partial_failure // "abort"' .devflow.yaml)
GATE_TESTS=$(yq e '.gates.require_tests_pass // "true"' .devflow.yaml)
GATE_LINT=$(yq e '.gates.require_lint_pass // "true"' .devflow.yaml)
DEPLOY_BEFORE_PR=$(yq e '.gates.deploy_before_pr // "false"' .devflow.yaml)
FALLBACK_MODE=$(yq e '.fallback.mode // "generic"' .devflow.yaml)
```

If `yq` is not available, use grep-based extraction.

---

## Step 3 — Generate task slug and run ID

```bash
TASK_SLUG=$(echo "$ARGUMENTS" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-*$//' | cut -c1-40)
RUN_ID="${TASK_SLUG}-$(date +%s)"
REPO_ROOT=$(git rev-parse --show-toplevel)
export DEVFLOW_RUN_ID="$RUN_ID"
```

---

## Step 4 — Start telemetry

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" start "$RUN_ID" "task=${ARGUMENTS}" "base_branch=${BASE_BRANCH}"
```

---

## Step 5 — Create worktree

```bash
WORKTREE=$("${CLAUDE_PLUGIN_ROOT}/scripts/worktree-create.sh" "$TASK_SLUG" "$BASE_BRANCH" "$REPO_ROOT")
```

If it exits non-zero, stop and show the error.

All subsequent file operations happen inside `$WORKTREE`.

---

## Step 6 — Plan

Using model `$MODEL_PLAN`, produce a structured plan for the task. The plan must identify:
- Which files/directories will be touched
- The list of scopes (for specialist discovery and fan-out)
- Sub-tasks that can be parallelized

Record the touched paths in `$TOUCHED_PATHS` (space-separated).

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=plan" "status=done"
```

---

## Step 7 — Discover specialists

```bash
SPECIALISTS=$("${CLAUDE_PLUGIN_ROOT}/scripts/discover-specialists.sh" $TOUCHED_PATHS 2>/dev/null || true)
```

If `SPECIALISTS` is empty:
- If `FALLBACK_MODE=refuse`: stop and ask the user to create a specialist agent in `.claude/agents/`.
- If `FALLBACK_MODE=generic`: use the generic agent at `"${CLAUDE_PLUGIN_ROOT}/agents/generic.md"`.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=discover" "specialists_found=$(echo "$SPECIALISTS" | grep -c '|' || echo 0)"
```

---

## Step 8 — Fan-out execution

Spawn specialist agents to implement the plan. Respect `$MAX_AGENTS` (cap parallel agents at this limit). Each specialist works exclusively in its own scope within `$WORKTREE`.

For each specialist agent:
- Provide: the plan for its scope, the worktree path, and the agent file
- The specialist must not open PRs, manage git flow, or run tests — that is the motor's job

Handle `$ON_PARTIAL` after all agents complete:
- `abort`: if any agent failed, stop the run, report failures, run cleanup
- `isolate`: continue with passing scopes, mark failed scopes in telemetry
- `retry`: re-run failed agents up to `retry_limit` times before applying `abort` behavior

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=execute" "status=done"
```

---

## Step 9 — Test gate

If `$CMD_TEST` is set:
```bash
cd "$WORKTREE" && eval "$CMD_TEST"
```

If tests fail and `$GATE_TESTS=true`:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" fail "$RUN_ID" "phase=test" "reason=tests_failed"
```
Stop and report. Do not proceed to lint, review, or PR.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=test" "status=passed"
```

---

## Step 10 — Lint gate

If `$CMD_LINT` is set:
```bash
cd "$WORKTREE" && eval "$CMD_LINT"
```

If lint fails and `$GATE_LINT=true`:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" fail "$RUN_ID" "phase=lint" "reason=lint_failed"
```
Stop and report.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=lint" "status=passed"
```

---

## Step 11 — Build (optional)

If `$CMD_BUILD` is set:
```bash
cd "$WORKTREE" && eval "$CMD_BUILD"
```

---

## Step 12 — Review

Perform a self-review of all changes in `$WORKTREE`. Check for:
- Correctness relative to the plan
- No hardcoded values that should come from config
- No regressions in adjacent code
- Adequate test coverage for the change

If issues are found, return to Step 8 for targeted re-execution. Track re-execution count in telemetry.

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=review" "status=passed"
```

---

## Step 13 — Pre-PR deploy (optional)

If `$CMD_DEPLOY` is set **and** `$DEPLOY_BEFORE_PR=true`:
```bash
cd "$WORKTREE" && eval "$CMD_DEPLOY"
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=deploy_pre_pr" "status=done"
```

---

## Step 14 — Commit and open PR

```bash
cd "$WORKTREE"
git add -A
git commit -m "feat: ${ARGUMENTS}"
git push origin "devflow/${TASK_SLUG}"
gh pr create \
  --title "feat: ${ARGUMENTS}" \
  --body "Automated by DevFlow run \`${RUN_ID}\`." \
  --base "$BASE_BRANCH"
```

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=pr" "status=opened"
```

---

## Step 15 — Post-PR deploy (optional)

If `$CMD_DEPLOY` is set **and** `$DEPLOY_BEFORE_PR=false`:
```bash
cd "$WORKTREE" && eval "$CMD_DEPLOY"
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=deploy_post_pr" "status=done"
```

---

## Step 16 — Cleanup

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/worktree-cleanup.sh" "$TASK_SLUG"
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" stop "$RUN_ID" "status=success"
```

Report the PR URL and a summary of phases completed.
