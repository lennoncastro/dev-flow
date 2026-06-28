# DevFlow

> **Status:** Pre-release — self-hosted marketplace available.

A Claude Code plugin that packages a complete AI-assisted development workflow. Stack-agnostic: the plugin owns the orchestration engine; each project that installs it brings its own stack conventions via `.claude/agents/` subagents.

## Installation

### Option A — Via marketplace (recommended)

One-time global setup. `/devflow` becomes available in all projects.

**Step 1** — Add to `~/.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "lennoncastro": {
      "source": { "source": "github", "repo": "lennoncastro/dev-flow" }
    }
  }
}
```

**Step 2** — Install:

```
claude plugin install devflow@lennoncastro
```

### Option B — Local project command (no setup needed)

No marketplace registration required. Works immediately in the project.

```bash
mkdir -p .claude/commands
curl -sL https://raw.githubusercontent.com/lennoncastro/dev-flow/main/skills/devflow/SKILL.md \
  -o .claude/commands/devflow.md
```

> **Note:** Adding `"plugins": [{ "source": { "source": "github", ... } }]` to `settings.json` does **not** download the plugin — it is a no-op for GitHub sources. Use Option A or B above.

**Requirements:** Claude Code CLI, `git`, `gh` (GitHub CLI, authenticated), `jq`. `yq` is optional — scripts fall back to grep if absent.

## Usage

From any project with a `.devflow.yaml`:

**Start a task:**

```
/devflow start add user authentication endpoint
```

DevFlow will:
1. Validate `.devflow.yaml`
2. Create an isolated git worktree from `base_branch`
3. Plan the task
4. Discover specialist agents by directory proximity
5. Fan-out execution to specialists
6. Run test and lint gates
7. Self-review
8. Open a PR (and optionally deploy)
9. Clean up the worktree

**Check run status:**

```
/devflow status
```

Shows all runs from `.devflow/runs/*.jsonl` — run ID, last event, status, timestamp.

## Creating a specialist

Add a `.claude/agents/<name>.md` anywhere in your repo. No declaration needed — placement is the routing signal.

```markdown
---
name: node-api
description: Node.js API specialist for this project
---

Follow the existing Express patterns in src/routes/.
Use the project's validation middleware (src/middleware/validate.ts).
Write tests with Vitest; place them alongside source files.
Do not introduce new dependencies without checking package.json first.
```

See [`docs/specialist-contract.md`](docs/specialist-contract.md) for the full format spec.

## Problem

Every team that adopts AI-assisted development ends up reinventing the same orchestration: create a branch, plan the work, execute with the right model, run tests, review, deploy, open a PR. DevFlow packages that loop into a versioned, installable plugin — so you configure once and stop rebuilding the scaffolding.

## How it works

Three layers with independent lifecycles:

| Layer | Lives in | Owns |
|---|---|---|
| **Motor** | Plugin hooks/scripts | Orchestration — worktree, plan, fan-out, gates |
| **Patterns** | Project's `.claude/agents/` | Stack conventions — idioms, linting rules, review standards |
| **Spec** | External tool (`spec.tool`) | Optional spec management |

The motor has zero knowledge of any stack. All variable config comes from `.devflow.yaml`; all stack rules come from specialists discovered in the project.

## Workflow cycle

```
worktree (from base_branch) → plan → fan-out execution → test → lint → review → deploy* → PR
```

`*` Deploy position is controlled by `gates.deploy_before_pr` (default `false` — PR approval is the gate).

## Quick start

### 1. Add `.devflow.yaml` to your project root

Minimal config:

```yaml
version: 1
base_branch: main
models:
  plan: claude-opus-4-8
  execution: claude-sonnet-4-6
commands:
  test: npm test
```

Full config with all optional fields:

```yaml
version: 1
base_branch: develop
models:
  plan: claude-opus-4-8
  execution: claude-sonnet-4-6
commands:
  test: npm test
  lint: npm run lint
  deploy: npm run deploy:preview
fan_out:
  enabled: true
  max_agents: 4
  on_partial_failure: isolate   # abort | isolate | retry
gates:
  deploy_before_pr: false
spec:
  tool: openspec
fallback:
  mode: generic                 # generic | refuse
```

### 3. Install the plugin

```
claude plugin install github:lennoncastro/dev-flow
```

### 4. Run your first task

```
/devflow start your task description here
```

### 2. Add specialists where they make sense

No declaration required. Place agent files anywhere in your repo — the motor discovers them by directory proximity:

```
your-repo/
  .devflow.yaml
  apps/
    api/
      .claude/agents/backend.md    # discovered for tasks touching apps/api/
    web/
      .claude/agents/frontend.md  # discovered for tasks touching apps/web/
  .claude/agents/generic.md        # fallback for everything else
```

## Specialist discovery

Before spawning executors, the motor walks the directory tree from each task-touched path upward, collecting `.claude/agents/` files. This is deterministic — a filesystem walk, not a model decision.

- **One scope touched** → one specialist activated
- **Multiple scopes** (monorepo / cross-cutting task) → fan-out, one agent per scope, capped by `fan_out.max_agents`
- **No agent found** → applies `fallback` (generic agent or refuse)

No `specialists:` block in config. Create agents where they make sense; the rest falls to the fallback.

## Configuration reference

| Field | Required | Default | Notes |
|---|---|---|---|
| `version` | yes | — | Schema version. Motor rejects incompatible values. |
| `base_branch` | yes | — | Worktrees are created from this branch. Motor never operates directly on it. |
| `models.plan` | yes | — | Model for the plan phase. |
| `models.execution` | yes | — | Model for execution / fan-out. |
| `models.review` | no | = `plan` | Model for the review phase. |
| `commands.test` | yes | — | Test suite command. |
| `commands.lint` | no | — | Skipped if absent. |
| `commands.build` | no | — | Skipped if absent. |
| `commands.deploy` | no | — | No deploy step if absent. |
| `fan_out.enabled` | no | `false` | Enables parallel execution. |
| `fan_out.max_agents` | no | `1` | Cap on parallel agents. |
| `fan_out.on_partial_failure` | no | `abort` | `abort` / `isolate` / `retry` |
| `gates.deploy_before_pr` | no | `false` | `true` = preview deploy before PR; `false` = PR approval is the gate. |
| `gates.require_tests_pass` | no | `true` | Blocks PR if tests fail. |
| `fallback.mode` | no | `generic` | `generic` uses the plugin's example agent; `refuse` stops and asks for a specialist. |
| `limits.max_tokens_per_run` | no | `0` | `0` = no limit. Recommended in distributed environments. |
| `telemetry.enabled` | no | `true` | Writes JSONL run logs to `telemetry.path`. |
| `telemetry.path` | no | `.devflow/runs/` | Directory for run logs. |

Full annotated schema: [`docs/devflow-schema.md`](docs/devflow-schema.md).

## Roadmap

1. Schema defined — `docs/devflow-schema.md` ✓
2. Specialist contract (format, discovery, routing, fallback) ✓
3. Motor hooks (parameterized, idempotent worktree cleanup) ✓
4. Run telemetry (JSONL → `.devflow/runs/`) ✓
5. Dogfood on single-stack fixture end-to-end ✓
6. Generalize for monorepo + fallback
7. Repo-fixtures + CI gate (required before any `git tag`)
8. Example specialist (illustrates format, no stack opinions) ✓
9. Package and publish to marketplace

## Contributing

**Golden rule: nothing project-specific in hooks.**

The motor must have zero hardcoded branches, commands, models, or stack conventions. Everything that varies between projects lives in `.devflow.yaml` or in the project's own specialist agents. Any project-specific detail inside the motor kills replicability and breaks the plugin's contract.

See [`docs/devflow-plugin-plan.md`](docs/devflow-plugin-plan.md) for full architecture rationale.
