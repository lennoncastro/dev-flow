---
name: devflow
description: DevFlow motor — AI-assisted development workflow. Usage: /devflow init | /devflow start [--auto-pr] [--dry-run] <task> | /devflow retry [run-id] | /devflow status | /devflow logs [run-id] | /devflow config | /devflow specialist add | /devflow doctor
---

Parse the first word of $ARGUMENTS as the subcommand. Everything after is the subcommand's arguments.

```bash
SUBCMD=$(echo "$ARGUMENTS" | awk '{print $1}')
SUBARGS=$(echo "$ARGUMENTS" | cut -d' ' -f2-)
```

---

## Subcommand: start

Triggered when `$SUBCMD = start`. Task description is `$SUBARGS`.

**Execution mode: fully autonomous. Run every step to completion without pausing, asking for confirmation, or stopping between steps. Only stop for: config validation failure (Step 1), worktree creation failure (Step 5), or test gate failure when require_tests_pass is true.**

First, parse flags from `$SUBARGS`:

```bash
DRY_RUN=false
if echo "$SUBARGS" | grep -q -- '--dry-run'; then
  DRY_RUN=true
  SUBARGS=$(echo "$SUBARGS" | sed 's/--dry-run//g' | xargs)
fi
```

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
MAX_TOKENS=$(yq e '.limits.max_tokens_per_run // "0"' .devflow.yaml 2>/dev/null || echo "0")
ON_LIMIT=$(yq e '.limits.on_limit // "confirm"' .devflow.yaml 2>/dev/null || echo "confirm")
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

If `$DRY_RUN=true`, skip worktree creation and set `WORKTREE="(dry run — no worktree created)"`. Continue to Step 6.

Otherwise:

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

If `$DRY_RUN=true`, stop here and display:

```
Dry run complete — no changes made.

  Task:        <SUBARGS>
  Run ID:      <RUN_ID> (dry run)
  Base branch: <BASE_BRANCH>
  Worktree:    (not created)

  Plan:
  <plan produced in Step 6>

  Specialists:
  <list of scope → agent file, or "none found — would use fallback: <FALLBACK_MODE>">

  Would execute:
    fan-out: <number of specialists> agents (max <MAX_AGENTS>)
    test:    <CMD_TEST>
    lint:    <CMD_LINT or "(skipped — not configured)">
    build:   <CMD_BUILD or "(skipped)">
    deploy:  <CMD_DEPLOY or "(skipped)">
    pr:      auto_pr=<AUTO_PR>

To run for real: /devflow start <SUBARGS>
```

Then stop. Do not proceed to Step 8.

### Step 8 — Fan-out execution

Spawn specialist agents to implement the plan. Respect `$MAX_AGENTS`. Each specialist works exclusively in its scope within `$WORKTREE`. Specialists must not open PRs, manage git, or run tests.

Handle `$ON_PARTIAL`:
- `abort` → any failure cancels the run
- `isolate` → continue with passing scopes, mark failures in telemetry
- `retry` → re-run failed agents up to `retry_limit` before abort

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" phase "$RUN_ID" "phase=execute" "status=done"
```

### Step 8b — Cost gate check

If `$MAX_TOKENS > 0`:

```bash
N_SPECIALISTS=$(echo "$SPECIALISTS" | grep -c '|' || echo 1)
ESTIMATED_TOKENS=$((5000 + N_SPECIALISTS * 20000 + 3000))
```

If `ESTIMATED_TOKENS > MAX_TOKENS`:
- If `ON_LIMIT=abort`: log and stop:
  ```bash
  "${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" fail "$RUN_ID" "phase=cost_gate" "reason=token_limit_exceeded" "estimated=$ESTIMATED_TOKENS" "limit=$MAX_TOKENS"
  ```
  Report: "Cost gate: estimated ~`$ESTIMATED_TOKENS` tokens exceeds limit of `$MAX_TOKENS`. Run aborted."
- If `ON_LIMIT=confirm`: ask user: "Estimated token usage (~`$ESTIMATED_TOKENS`) exceeds configured limit (`$MAX_TOKENS`). Continue? (y/n)" — abort if n, continue if y.

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

## Subcommand: retry

Triggered when `$SUBCMD = retry`. Optional run ID in `$SUBARGS`.

### Step 1 — Find the run

```bash
TELEMETRY_DIR=$(yq e '.telemetry.path // ".devflow/runs/"' .devflow.yaml 2>/dev/null || echo ".devflow/runs/")
if [ -n "$SUBARGS" ] && [ "$SUBARGS" != "$SUBCMD" ]; then
  RUN_FILE="${TELEMETRY_DIR}/${SUBARGS}.jsonl"
else
  RUN_FILE=$(ls -t "${TELEMETRY_DIR}"*.jsonl 2>/dev/null | head -1)
fi
```

If no file found: "No run found. Use /devflow status to list runs."

### Step 2 — Determine failed phase

Read the JSONL and find the last `fail` event or the last `phase` event before `stop`:

```bash
FAILED_PHASE=$(grep '"event":"fail"' "$RUN_FILE" | tail -1 | jq -r '.phase // "unknown"')
RUN_ID=$(basename "$RUN_FILE" .jsonl)
TASK=$(grep '"event":"start"' "$RUN_FILE" | head -1 | jq -r '.task // ""' | sed 's/task=//')
```

Show: "Run `$RUN_ID` failed at phase `$FAILED_PHASE`. Retrying from `$FAILED_PHASE`..."

Log the retry event:
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" retry "$RUN_ID" "from_phase=$FAILED_PHASE"
```

### Step 3 — Read config and restore state

Re-read `.devflow.yaml` (same as start Step 2). Restore:
```bash
TASK_SLUG=$(echo "$RUN_ID" | sed 's/-[0-9]*$//')
REPO_ROOT=$(git rev-parse --show-toplevel)
WORKTREE_PATH="${REPO_ROOT}/.devflow/worktrees/${TASK_SLUG}"
```

### Step 4 — Restore or recreate worktree

If `$WORKTREE_PATH` exists: use it.
Otherwise: recreate with `scripts/worktree-create.sh "$TASK_SLUG" "$BASE_BRANCH" "$REPO_ROOT"`.

### Step 5 — Resume from failed phase

Check which phases already passed by scanning the JSONL for `"status":"passed"` events. Skip those phases. Resume the start workflow from `$FAILED_PHASE`.

Phases that can be retried: `execute`, `test`, `lint`, `review`, `pr`.

If `$FAILED_PHASE` is `plan` or earlier: restart from Step 6 of start.
If `$FAILED_PHASE` is `execute`: restart from Step 8.
If `$FAILED_PHASE` is `test`: restart from Step 9.
If `$FAILED_PHASE` is `lint`: restart from Step 10.
If `$FAILED_PHASE` is `review`: restart from Step 12.
If `$FAILED_PHASE` is `pr`: restart from Step 14.

Continue the start workflow normally from the resumed phase through cleanup.

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

## Subcommand: logs

Triggered when `$SUBCMD = logs`. Optional run ID in `$SUBARGS`.

### Step 1 — Find the JSONL

```bash
TELEMETRY_DIR=$(yq e '.telemetry.path // ".devflow/runs/"' .devflow.yaml 2>/dev/null || echo ".devflow/runs/")
if [ -n "$SUBARGS" ] && [ "$SUBARGS" != "$SUBCMD" ]; then
  RUN_FILE="${TELEMETRY_DIR}/${SUBARGS}.jsonl"
else
  RUN_FILE=$(ls -t "${TELEMETRY_DIR}"*.jsonl 2>/dev/null | head -1)
  MULTIPLE=$(ls "${TELEMETRY_DIR}"*.jsonl 2>/dev/null | wc -l)
fi
```

If no file found: "No runs found in `$TELEMETRY_DIR`."

### Step 2 — Parse and display timeline

Read all lines from the JSONL. For each event, extract `ts`, `event`, `phase`, `status`, and any extra fields.

Display as a timeline:

```
Run: <run-id>
─────────────────────────────────────────────────────────────
  <time>  start      task="<task>"
  <time>  phase      plan          ✅  <duration>
  <time>  phase      discover      ✅  <duration>  specialists=<n>
  <time>  phase      execute       ✅  <duration>
  <time>  phase      test          ✅  <duration>
  <time>  phase      lint          ✅  <duration>
  <time>  phase      review        ✅  <duration>
  <time>  phase      pr            ✅  <duration>  url=<pr-url>
  <time>  stop       status=success  total=<total-duration>
─────────────────────────────────────────────────────────────
```

For `fail` events use ❌ instead of ✅. Calculate duration between consecutive timestamps. Show total elapsed from start to stop/fail.

If `$MULTIPLE > 1` and no run-id was specified, append: "(showing latest — use /devflow logs <run-id> to see others)"

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

### Step 7 — Register hook permissions

Resolve the plugin scripts path and add an allow rule to `.claude/settings.json` so hook scripts can run without permission prompts.

```bash
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
else
  PLUGIN_SCRIPTS=$(ls -d ~/.claude/plugins/cache/lennoncastro/devflow/*/scripts 2>/dev/null | tail -1)
fi
```

If `$PLUGIN_SCRIPTS` is non-empty, merge the allow rule into `.claude/settings.json`:

```bash
mkdir -p .claude
python3 - <<PYEOF
import json, os
path = ".claude/settings.json"
cfg = json.load(open(path)) if os.path.exists(path) else {}
perms = cfg.setdefault("permissions", {})
allow = perms.setdefault("allow", [])
rule = 'Bash(bash "${PLUGIN_SCRIPTS}/*")'
if rule not in allow:
    allow.append(rule)
json.dump(cfg, open(path, "w"), indent=2)
PYEOF
```

Replace `${PLUGIN_SCRIPTS}` in the rule string with the actual resolved value of `$PLUGIN_SCRIPTS` before writing.

### Step 9 — Write specialist agent

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

### Step 10 — Report

Determine the recommended Claude Code skill for the detected stack:
- flutter → `flutter-expert`
- typescript → `typescript-pro`
- node → `javascript-pro`
- python → `python-pro`
- go → `golang-pro`
- rust → `rust-engineer`
- android → `kotlin-specialist`
- generic → (no suggestion)

Check if the plugin cache is stale:

```bash
CACHED_VERSION=$(python3 -c "
import json, sys
try:
    d = json.load(open('${PLUGIN_SCRIPTS}/../../../marketplace.json'))
    print(d['plugins'][0]['version'])
except:
    print('unknown')
" 2>/dev/null || echo "unknown")
SOURCE_VERSION=$(grep -E '^version:' .devflow.yaml | awk '{print $2}' | tr -d '"' || echo "unknown")
```

If `$CACHED_VERSION` is not `"unknown"` and `$SOURCE_VERSION` is not `"unknown"` and they differ, print:

```
⚠  Plugin cache may be stale (cache: <CACHED_VERSION>, config: <SOURCE_VERSION>).
   Run: claude plugin update devflow@lennoncastro
```

Print the files created and next steps:

```
Done.
  Created: .devflow.yaml
  Created: .claude/agents/<stack>.md
  Updated: .claude/settings.json (hook permissions)

Next: /devflow start <task description>
Tip: your specialist at .claude/agents/<stack>.md can invoke the `<skill>` skill for deeper stack knowledge.
```

Omit the Tip line for generic stack. Omit the `settings.json` line if `$PLUGIN_SCRIPTS` was empty.

---

## Subcommand: config

Triggered when `$SUBCMD = config`.

If `.devflow.yaml` does not exist, respond: "No .devflow.yaml found. Run /devflow init first." and stop.

This is an **interactive wizard**. Read the current `.devflow.yaml`, then guide the user through reviewing and changing settings conversationally — one group at a time. Do not dump raw YAML. Do not process `get`/`set` as flags — just run the wizard.

---

### Step 1 — Read current config

Read all fields from `.devflow.yaml` using yq (or grep fallback).

### Step 2 — Show summary and open the wizard

Display current values in a friendly, readable format:

```
DevFlow config — current settings

  Base branch:    main
  Plan model:     claude-opus-4-8
  Exec model:     claude-sonnet-4-6

  Commands:
    test:   flutter test
    lint:   flutter analyze
    build:  (not set)
    deploy: (not set)

  Fan-out:    disabled
  Auto PR:    false
  Fallback:   generic
  Telemetry:  enabled → .devflow/runs/
```

Then ask:

"Which setting would you like to change? You can say the name (e.g. 'base branch', 'test command', 'auto pr') or type a number:

  1. Base branch
  2. Models (plan / execution)
  3. Commands (test / lint / build / deploy)
  4. Fan-out
  5. Gates (auto PR / deploy / test gate / lint gate)
  6. Fallback mode
  7. Telemetry
  8. Done"

### Step 3 — Handle user selection

Wait for user response, then guide them through the relevant setting:

**1 — Base branch:** "Current: `<value>`. New value?" → update `base_branch`

**2 — Models:** Ask plan model first ("Current plan model: `<value>`. New value or Enter to keep?"), then execution model.

**3 — Commands:** Go through test, lint, build, deploy one by one. For each: show current value, ask for new value or Enter to keep. "(not set)" means the command is optional and currently absent — user can type a command or Enter to leave unset.

**4 — Fan-out:** "Fan-out is currently `<enabled/disabled>`. Enable it? (y/n)" → if yes, ask max_agents and on_partial_failure.

**5 — Gates:** Go through auto_pr, deploy_before_pr, require_tests_pass, require_lint_pass. For booleans: show current, ask "y/n or Enter to keep".

**6 — Fallback mode:** "Current: `<generic/refuse>`. Change to `<the other option>`? (y/n)"

**7 — Telemetry:** "Telemetry is `<enabled/disabled>`. Toggle? (y/n)" → if enabled, also ask path.

**8 — Done:** Stop the wizard.

### Step 4 — Apply changes

After collecting all changes for the selected group, update `.devflow.yaml` using:

For string values:
```bash
yq e -i ".<key> = \"<value>\"" .devflow.yaml
```

For boolean values:
```bash
yq e -i ".<key> = <true|false>" .devflow.yaml
```

If yq is not available, write the full file manually with the updated values using the Write tool.

### Step 5 — Confirm and loop

After applying, show what changed:
```
Updated:
  commands.lint = flutter analyze
  gates.auto_pr = true
```

Then ask: "Anything else to change? (number or 'done')" — loop back to Step 3 until user says done or types 8.

---

## Subcommand: specialist

Triggered when `$SUBCMD = specialist`.

If `$SUBARGS` is not `add`, respond: "Usage: /devflow specialist add"

### Interactive wizard — /devflow specialist add

Ask each question and wait for the user's answer before proceeding:

**Step 1:** "Name for this specialist? (e.g. backend, frontend, mobile)"
→ Store as `SPEC_NAME`

**Step 2:** "Which directory should this specialist cover? (path relative to repo root, or '.' for root)"
→ Store as `SPEC_DIR`

**Step 3:** "Describe what this specialist knows (e.g. 'Node.js/Express API, Jest tests, TypeScript strict')"
→ Store as `SPEC_DESC`

**Step 4:** "Any libraries or patterns to always follow? (Enter to skip)"
→ Store as `SPEC_FOLLOW` (empty = skip)

**Step 5:** "Any libraries or patterns to avoid? (Enter to skip)"
→ Store as `SPEC_AVOID` (empty = skip)

### Generate the specialist file

Target path: `<SPEC_DIR>/.claude/agents/<SPEC_NAME>.md`
(If `SPEC_DIR = "."`, path is `.claude/agents/<SPEC_NAME>.md`)

Create the directory if needed. Write the file:

```markdown
---
name: <SPEC_NAME>
description: <SPEC_DESC>
---

<SPEC_DESC>.
<If SPEC_FOLLOW non-empty: "Always follow: <SPEC_FOLLOW>.">
<If SPEC_AVOID non-empty: "Avoid: <SPEC_AVOID>.">
Write tests consistent with the existing setup.
No new dependencies without checking existing manifests first.
```

Confirm: "Created `<path>` — covers `<SPEC_DIR>`"

Tip: the motor will discover this specialist automatically for tasks touching files under `<SPEC_DIR>`. No declaration needed.

---

## Subcommand: abort

Triggered when `$SUBCMD = abort`. Optional run ID in `$SUBARGS`.

### Step 1 — Find the run

```bash
TELEMETRY_DIR=$(grep -A1 'path:' .devflow.yaml 2>/dev/null | tail -1 | awk '{print $2}' || echo ".devflow/runs/")
if [ -n "$SUBARGS" ] && [ "$SUBARGS" != "$SUBCMD" ]; then
  RUN_FILE="${TELEMETRY_DIR}/${SUBARGS}.jsonl"
else
  RUN_FILE=$(ls -t "${TELEMETRY_DIR}"*.jsonl 2>/dev/null | head -1)
fi
```

If no file found: "No run found. Use /devflow status to list runs." and stop.

Read the last event from the JSONL:

```bash
RUN_ID=$(basename "$RUN_FILE" .jsonl)
LAST_EVENT=$(tail -1 "$RUN_FILE" | python3 -c 'import json,sys; e=json.load(sys.stdin); print(e.get("event",""))' 2>/dev/null || true)
LAST_STATUS=$(tail -1 "$RUN_FILE" | python3 -c 'import json,sys; e=json.load(sys.stdin); print(e.get("status",""))' 2>/dev/null || true)
```

If `$LAST_EVENT` is `stop` or `$LAST_EVENT` is `abort`: "Run `$RUN_ID` is already finished (status: `$LAST_STATUS`). Nothing to abort." and stop.

### Step 2 — Confirm

Extract context from the JSONL:

```bash
TASK=$(grep '"event":"start"' "$RUN_FILE" | head -1 | python3 -c 'import json,sys; e=json.load(sys.stdin); print(e.get("task",""))' 2>/dev/null | sed 's/task=//' || true)
LAST_PHASE=$(grep '"event":"phase"' "$RUN_FILE" | tail -1 | python3 -c 'import json,sys; e=json.load(sys.stdin); print(e.get("phase","unknown"))' 2>/dev/null || true)
TASK_SLUG=$(echo "$RUN_ID" | sed 's/-[0-9]*$//')
WORKTREE_PATH="${REPO_ROOT:-$(git rev-parse --show-toplevel)}/.devflow/worktrees/${TASK_SLUG}"
WORKTREE_EXISTS="(not created)"
[ -d "$WORKTREE_PATH" ] && WORKTREE_EXISTS="$WORKTREE_PATH"
```

Show:

```
Abort run <RUN_ID>?
  Task:     <TASK>
  Phase:    <LAST_PHASE>
  Worktree: <WORKTREE_EXISTS>

This will: log abort, delete worktree, delete remote branch (if pushed).
Proceed? (y/N)
```

Wait for user confirmation. If N, empty, or anything other than `y`/`yes`: "Aborted. Run continues." and stop.

### Step 3 — Log abort

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/telemetry.sh" fail "$RUN_ID" "phase=abort" "reason=user_aborted"
```

### Step 4 — Clean up worktree

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/worktree-cleanup.sh" "$TASK_SLUG"
```

### Step 5 — Delete remote branch (if pushed)

```bash
BRANCH="devflow/${TASK_SLUG}"
BRANCH_DELETED="not pushed — nothing to delete"
if git ls-remote --heads origin "$BRANCH" 2>/dev/null | grep -q "$BRANCH"; then
  git push origin --delete "$BRANCH" 2>/dev/null && BRANCH_DELETED="devflow/${TASK_SLUG}" || true
fi
```

### Step 6 — Report

```
Run <RUN_ID> aborted.
  Worktree removed: .devflow/worktrees/<TASK_SLUG>  (or "not found — nothing to remove")
  Branch deleted:   <BRANCH_DELETED>
```

---

## Subcommand: doctor

Triggered when `$SUBCMD = doctor`.

Run a series of environment and configuration checks. Print each result as a checklist line with ✅ or ❌.

### Step 1 — Initialize counters and output

```bash
ISSUES=0
OUTPUT=""
```

### Step 2 — Check .devflow.yaml

```bash
if [ ! -f ".devflow.yaml" ]; then
  OUTPUT="${OUTPUT}\n  ❌  .devflow.yaml — not found (run /devflow init)"
  ISSUES=$((ISSUES + 1))
  CONFIG_MISSING=true
else
  CONFIG_MISSING=false
  # Validate config
  if "${CLAUDE_PLUGIN_ROOT}/scripts/validate-config.sh" ".devflow.yaml" &>/dev/null; then
    OUTPUT="${OUTPUT}\n  ✅  .devflow.yaml — found and valid"
  else
    OUTPUT="${OUTPUT}\n  ❌  .devflow.yaml — found but invalid (run /devflow config)"
    ISSUES=$((ISSUES + 1))
  fi
fi
```

### Step 3 — Config field checks (skip if config missing)

If `$CONFIG_MISSING = false`:

```bash
BASE_BRANCH=$(grep -E '^base_branch:' .devflow.yaml | awk '{print $2}' | tr -d '"' | tr -d "'" || true)
if [ -n "$BASE_BRANCH" ]; then
  OUTPUT="${OUTPUT}\n  ✅  base_branch: ${BASE_BRANCH}"
else
  OUTPUT="${OUTPUT}\n  ❌  base_branch: not set"
  ISSUES=$((ISSUES + 1))
fi

CMD_TEST=$(grep -E '^  test:' .devflow.yaml | awk '{$1=""; print $0}' | xargs || true)
if [ -n "$CMD_TEST" ]; then
  OUTPUT="${OUTPUT}\n  ✅  commands.test: ${CMD_TEST}"
else
  OUTPUT="${OUTPUT}\n  ❌  commands.test: not set (required)"
  ISSUES=$((ISSUES + 1))
fi

CMD_LINT=$(grep -E '^  lint:' .devflow.yaml | awk '{$1=""; print $0}' | xargs || true)
if [ -n "$CMD_LINT" ]; then
  OUTPUT="${OUTPUT}\n  ✅  commands.lint: ${CMD_LINT}"
else
  OUTPUT="${OUTPUT}\n  ❌  commands.lint: not set (optional)"
fi
```

If `$CONFIG_MISSING = true`, add ❌ lines for base_branch and commands.test and increment ISSUES for each.

### Step 4 — Tool availability checks

```bash
for tool in git gh python3; do
  if command -v "$tool" &>/dev/null; then
    OUTPUT="${OUTPUT}\n  ✅  ${tool} — available"
  else
    OUTPUT="${OUTPUT}\n  ❌  ${tool} — not found (required)"
    ISSUES=$((ISSUES + 1))
  fi
done

if command -v jq &>/dev/null; then
  OUTPUT="${OUTPUT}\n  ✅  jq — available"
else
  OUTPUT="${OUTPUT}\n  ❌  jq — not found (required by scripts)"
  ISSUES=$((ISSUES + 1))
fi
```

### Step 5 — Hook scripts executable

```bash
if [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/guard-base-branch.sh" ]; then
  OUTPUT="${OUTPUT}\n  ✅  Hook scripts — executable"
else
  OUTPUT="${OUTPUT}\n  ❌  Hook scripts — not executable (run: chmod +x ${CLAUDE_PLUGIN_ROOT}/scripts/*.sh)"
  ISSUES=$((ISSUES + 1))
fi
```

### Step 6 — Specialist discovery

```bash
SPECIALISTS=$("${CLAUDE_PLUGIN_ROOT}/scripts/discover-specialists.sh" . 2>/dev/null || true)
if [ -n "$SPECIALISTS" ]; then
  SPEC_COUNT=$(echo "$SPECIALISTS" | grep -c '|' || echo 1)
  OUTPUT="${OUTPUT}\n  ✅  Specialists found: ${SPEC_COUNT}"
else
  OUTPUT="${OUTPUT}\n  ❌  Specialists: none found (fallback will be used)"
fi
```

### Step 7 — Telemetry dir writable

```bash
TELEMETRY_DIR=".devflow/runs/"
if [ -f ".devflow.yaml" ]; then
  CONFIGURED=$(grep -E '^\s*path:' .devflow.yaml | awk '{print $2}' | tr -d '"' | tr -d "'" || true)
  [ -n "$CONFIGURED" ] && TELEMETRY_DIR="$CONFIGURED"
fi

mkdir -p "$TELEMETRY_DIR" 2>/dev/null || true
if [ -w "$TELEMETRY_DIR" ]; then
  OUTPUT="${OUTPUT}\n  ✅  Telemetry dir: ${TELEMETRY_DIR} (writable)"
else
  OUTPUT="${OUTPUT}\n  ❌  Telemetry dir: ${TELEMETRY_DIR} (not writable)"
  ISSUES=$((ISSUES + 1))
fi
```

### Step 8 — Print results

Print the header, all checklist lines, footer, and summary:

```
DevFlow doctor
──────────────────────────────────────────
<OUTPUT lines>
──────────────────────────────────────────
```

Then:
- If `$ISSUES = 0`: `All checks passed.`
- If `$ISSUES > 0`: `$ISSUES issue(s) found. Run /devflow init to fix setup issues.`

---

## Unknown subcommand

If `$SUBCMD` is not `init`, `start`, `status`, `retry`, `logs`, `config`, `specialist`, `abort`, or `doctor`, respond:

```
DevFlow: unknown subcommand '$SUBCMD'. Usage:
  /devflow init
  /devflow start [--auto-pr] [--dry-run] <task description>
  /devflow retry [run-id]
  /devflow abort [run-id]
  /devflow status
  /devflow logs [run-id]
  /devflow config
  /devflow specialist add
  /devflow doctor
```
