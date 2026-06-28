---
name: devflow
description: DevFlow motor — AI-assisted development workflow. Usage: /devflow init | /devflow start [--auto-pr] <task> | /devflow status
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
AUTO_PR=$(yq e '.gates.auto_pr // "false"' .devflow.yaml 2>/dev/null || echo "false")
FALLBACK_MODE=$(yq e '.fallback.mode // "generic"' .devflow.yaml 2>/dev/null || echo "generic")
```

If `$SUBARGS` contains `--auto-pr`, set `AUTO_PR=true` and strip the flag from the task description:

```bash
if echo "$SUBARGS" | grep -q -- '--auto-pr'; then
  AUTO_PR=true
  SUBARGS=$(echo "$SUBARGS" | sed 's/--auto-pr//g' | xargs)
fi
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
```

If `$AUTO_PR=true`, open the PR immediately without asking:

```bash
gh pr create --title "feat: $SUBARGS" --body "Automated by DevFlow run \`$RUN_ID\`." --base "$BASE_BRANCH"
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=pr" "status=opened"
```

If `$AUTO_PR=false`, show the command and ask the user to confirm before running:

```
Ready to open PR. Run this command to proceed:
  gh pr create --title "feat: $SUBARGS" --body "Automated by DevFlow run `$RUN_ID`." --base "$BASE_BRANCH"

Open the PR? (y/N)
```

Only run `gh pr create` after the user confirms.

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

## Subcommand: init

Triggered when `$SUBCMD = init` (or when `$ARGUMENTS` is empty).

Set up DevFlow in the current project: detect stack, generate `.devflow.yaml` and a specialist agent.

### Step 1 — Check for existing config

```bash
if [ -f ".devflow.yaml" ]; then
  echo "Warning: .devflow.yaml already exists. Overwrite? (y/N)"
fi
```

If the file exists, ask the user before proceeding. If they say no, stop.

### Step 2 — Detect base branch

```bash
BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
BASE_BRANCH="${BASE_BRANCH:-main}"
```

### Step 3 — Detect stack

Check for these files in the current directory, in order:

```bash
if [ -f "pubspec.yaml" ]; then
  STACK="flutter"
elif [ -f "package.json" ] && [ -f "tsconfig.json" ]; then
  STACK="typescript"
elif [ -f "package.json" ]; then
  STACK="node"
elif [ -f "pyproject.toml" ] || [ -f "requirements.txt" ]; then
  STACK="python"
elif [ -f "go.mod" ]; then
  STACK="go"
elif [ -f "Cargo.toml" ]; then
  STACK="rust"
elif [ -f "build.gradle" ] || [ -f "build.gradle.kts" ]; then
  STACK="android"
else
  STACK="generic"
fi
```

### Step 4 — Determine commands per stack

Based on `$STACK`:

**flutter:** `CMD_TEST="flutter test"`, `CMD_LINT="flutter analyze"`, `CMD_BUILD="flutter build apk"`

**typescript / node:** Check `package.json` scripts block. If `test` key exists, `CMD_TEST="npm run test"`. If `lint` key exists, `CMD_LINT="npm run lint"`. If `build` key exists, `CMD_BUILD="npm run build"`.

**python:** Check if `pytest` is in `pyproject.toml` or `requirements.txt` — if so, `CMD_TEST="pytest"`, else `CMD_TEST="python -m unittest"`. Check for `ruff` → `CMD_LINT="ruff check ."`, else `CMD_LINT="flake8"`.

**go:** `CMD_TEST="go test ./..."`, `CMD_LINT="go vet ./..."`

**rust:** `CMD_TEST="cargo test"`, `CMD_LINT="cargo clippy"`

**android:** `CMD_TEST="./gradlew test"`, `CMD_LINT="./gradlew lint"`

**generic:** `CMD_TEST='echo "configure commands.test in .devflow.yaml"'`, no lint/build.

### Step 5 — Show detected values

Print a summary before writing anything:

```
Detected:
  stack:       <STACK>
  base_branch: <BASE_BRANCH>
  test:        <CMD_TEST>
  lint:        <CMD_LINT or "(none)">
  build:       <CMD_BUILD or "(none)">

Creating .devflow.yaml and .claude/agents/<stack>.md ...
```

### Step 6 — Write .devflow.yaml

Write the file at `.devflow.yaml` with the detected values. Omit `commands.lint` and `commands.build` if not detected. Always include `fallback.mode: generic` and `telemetry.enabled: true`.

Example output for Flutter:
```yaml
version: 1
base_branch: main
models:
  plan: claude-opus-4-8
  execution: claude-sonnet-4-6
commands:
  test: flutter test
  lint: flutter analyze
  build: flutter build apk
fallback:
  mode: generic
telemetry:
  enabled: true
  path: .devflow/runs/
```

### Step 7 — Write specialist agent

Create `.claude/agents/<stack>.md` if it does not already exist. Use the template for the detected stack:

**flutter** → `.claude/agents/flutter.md`:
```markdown
---
name: flutter
description: Flutter/Dart specialist
---

Use Flutter 3+ with Dart. Prefer Riverpod for state management if already used.
Follow existing widget patterns in lib/. Use StatelessWidget unless state is needed.
Colocate tests in test/ mirroring lib/ structure.
No new pub dependencies without checking pubspec.yaml first.
Run `flutter analyze` before considering a change done.
```

**typescript** → `.claude/agents/typescript.md`:
```markdown
---
name: typescript
description: TypeScript/Node.js specialist
---

TypeScript strict mode. Follow existing tsconfig.json settings.
Prefer functional patterns. Follow existing folder structure in src/.
Write tests alongside source files using the existing test runner.
No new dependencies without checking package.json first.
```

**node** → `.claude/agents/node.md`:
```markdown
---
name: node
description: Node.js/JavaScript specialist
---

Follow existing code style and folder structure.
Write tests alongside source files using the existing test runner.
No new dependencies without checking package.json first.
Prefer async/await over callbacks.
```

**python** → `.claude/agents/python.md`:
```markdown
---
name: python
description: Python specialist
---

Follow PEP 8 and existing code style. Use type hints throughout.
Follow existing project structure. Write tests in tests/ with pytest.
No new dependencies without checking pyproject.toml or requirements.txt first.
Use existing virtual environment conventions.
```

**go** → `.claude/agents/golang.md`:
```markdown
---
name: golang
description: Go specialist
---

Follow standard Go conventions and existing package structure.
Error handling: always check and wrap errors with context.
Write table-driven tests in *_test.go files alongside source.
No new module dependencies without checking go.mod first.
```

**rust** → `.claude/agents/rust.md`:
```markdown
---
name: rust
description: Rust specialist
---

Follow existing module structure. Use idiomatic Rust — prefer iterators, avoid clone.
Write tests in the same file under #[cfg(test)].
No new crate dependencies without checking Cargo.toml first.
Run `cargo clippy` before considering a change done.
```

**android** → `.claude/agents/android.md`:
```markdown
---
name: android
description: Android/Kotlin specialist
---

Follow existing Kotlin code style and architecture patterns.
Use existing dependency injection setup. Write unit tests with JUnit.
No new Gradle dependencies without checking build.gradle first.
Run `./gradlew lint` before considering a change done.
```

**generic** → `.claude/agents/generic-specialist.md`:
```markdown
---
name: generic-specialist
description: Generic specialist — reads and follows project conventions
---

Read existing code patterns before writing anything.
Follow the conventions already established in the codebase.
Write tests consistent with the existing test setup.
No new dependencies without checking existing manifests first.
```

### Step 8 — Report

Determine the recommended Claude Code skill for the detected stack:
- flutter → `flutter-expert`
- typescript → `typescript-pro`
- node → `javascript-pro`
- python → `python-pro`
- go → `golang-pro`
- rust → `rust-engineer`
- android → `kotlin-specialist`
- generic → (no suggestion)

Print the files created and next steps:

```
Done.
  Created: .devflow.yaml
  Created: .claude/agents/<stack>.md

Next: /devflow start <task description>
Tip: your specialist at .claude/agents/<stack>.md can invoke the `<skill>` skill for deeper stack knowledge.
```

Omit the Tip line for generic stack.

---

## Unknown subcommand

If `$SUBCMD` is not `init`, `start`, or `status`, respond:

```
DevFlow: unknown subcommand '$SUBCMD'. Usage:
  /devflow init
  /devflow start <task description>
  /devflow status
```
