# DevFlow

> **Status:** In marketplace review.

A Claude Code plugin that packages a complete AI-assisted development workflow. Stack-agnostic: the motor orchestrates; each project brings its own stack conventions via `.claude/agents/` specialists.

## Installation

### Option A — Via marketplace (recommended)

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

### Option B — Local project command

No marketplace registration required.

```bash
mkdir -p .claude/commands
curl -sL https://raw.githubusercontent.com/lennoncastro/dev-flow/main/skills/devflow/SKILL.md \
  -o .claude/commands/devflow.md
```

**Requirements:** Claude Code CLI, `git`, `gh` (authenticated), `jq`. `yq` optional — scripts fall back to grep.

## Quick start

```bash
# 1. Initialize DevFlow in your project
/devflow init

# 2. Run a task
/devflow start add user authentication endpoint

# 3. Check run status
/devflow status
```

`init` detects your stack, writes `.devflow.yaml`, and creates a starter specialist in `.claude/agents/`.

## Commands

| Command | Description |
|---|---|
| `/devflow init` | Detect stack, generate `.devflow.yaml` and starter specialist |
| `/devflow start <task>` | Run the full workflow for a task |
| `/devflow plan <task>` | Plan only — no execution, no PR |
| `/devflow queue <t1> && <t2>` | Run multiple tasks in sequence |
| `/devflow retry [run-id]` | Retry from the failed phase |
| `/devflow pause [run-id]` | Pause a run after the current phase |
| `/devflow resume [run-id]` | Resume a paused run |
| `/devflow abort [run-id]` | Cancel a run and log failure |
| `/devflow status [--watch]` | Show status of all runs |
| `/devflow logs [run-id]` | Show phase timeline for a run |
| `/devflow open [run-id]` | Open the run's PR in the browser |
| `/devflow diff [run-id]` | Show git diff of the run's worktree |
| `/devflow history` | Full run history with filters |
| `/devflow config [show]` | Edit or view `.devflow.yaml` |
| `/devflow specialist add` | Add a specialist (gallery or custom) |
| `/devflow specialist validate` | Lint all `.claude/agents/` files |
| `/devflow doctor` | Check config, tools, scripts, worktrees |
| `/devflow clean` | Remove stale worktrees |
| `/devflow rollback [run-id]` | Revert a run's changes |
| `/devflow gc [--older-than=Nd]` | Delete old telemetry files |
| `/devflow update` | Sync plugin to latest version |

`/devflow start` flags: `--auto-pr` (open PR without confirmation), `--dry-run` (plan only, no worktree).

`/devflow history` filters: `--status=<success\|failed\|running>`, `--since=<7d\|24h>`, `--task=<keyword>`.

## Workflow

```
worktree (from base_branch) → plan → discover specialists → fan-out execution
  → test gate → lint gate → diff review → open PR → CI polling → cleanup
```

Each phase is logged to `.devflow/runs/<run-id>.jsonl`.

## Bug workflow

Bugs use the same command — no special mode needed:

```
/devflow start "fix: login button unresponsive after token refresh"
```

The specialist handles investigation. A good specialist for bug-prone code includes a `## Debugging` section that tells the motor to reproduce before fixing:

```markdown
## Debugging

When the task starts with "fix:", before writing any code:
1. Reproduce the error — add a failing test or run the scenario manually
2. Identify the root cause from logs or stack trace
3. Fix, then confirm the reproduction step now passes
```

The motor passes the task to the specialist — the specialist decides how to investigate. Different stacks debug differently: Flutter reads logs, Django checks tracebacks, Postgres runs `EXPLAIN ANALYZE`. That knowledge lives in the specialist, not the motor.

## Specialists

Specialists live in `.claude/agents/<name>.md`. No declaration in config — placement is the routing signal.

```markdown
---
name: backend
description: Node.js API specialist
---

Follow existing Express patterns in src/routes/.
Use the project's validation middleware.
Write tests with Vitest alongside source files.
No new dependencies without checking package.json first.

## Debugging

When the task starts with "fix:", reproduce the error first.
Check logs in logs/ or run with DEBUG=* to capture the trace.
Write a failing test before touching the fix.
```

Create specialists with `/devflow specialist add` (includes gallery of templates for React, Next.js, FastAPI, Django, Flutter, etc.) or write manually following [`agents/example.md`](agents/example.md).

See [`docs/specialist-contract.md`](docs/specialist-contract.md) for the full format spec.

## Configuration

Minimal `.devflow.yaml`:

```yaml
version: 1
base_branch: main
models:
  plan: claude-opus-4-8
  execution: claude-sonnet-4-6
commands:
  test: npm test
fallback:
  mode: generic
telemetry:
  enabled: true
```

Full reference: [`docs/devflow-schema.md`](docs/devflow-schema.md).

## How it works

Three layers with independent lifecycles:

| Layer | Lives in | Owns |
|---|---|---|
| **Motor** | Plugin hooks/scripts | Orchestration — worktree, plan, fan-out, gates |
| **Patterns** | Project's `.claude/agents/` | Stack conventions, debugging approach, review standards |
| **Config** | `.devflow.yaml` | Per-project variables (branch, models, commands, limits) |

The motor has zero knowledge of any stack. All variable config comes from `.devflow.yaml`; all stack rules come from discovered specialists.

## Specialist discovery

The motor walks upward from each task-touched path, collecting `.claude/agents/` files. Deterministic — filesystem walk, not model choice.

- One scope → one specialist
- Multiple scopes (monorepo) → fan-out, one agent per scope, capped by `fan_out.max_agents`
- No agent found → `fallback.mode` applies (`generic` or `refuse`)

## Roadmap

1. Schema defined ✓
2. Specialist contract ✓
3. Motor hooks ✓
4. Run telemetry ✓
5. Dogfood on single-stack fixture ✓
6. Generalize for monorepo + fallback ✓
7. Repo fixtures + CI gate ✓
8. Example specialist ✓
9. Publish to marketplace — in review

## Contributing

**Golden rule: nothing project-specific in hooks.**

The motor must have zero hardcoded branches, commands, models, or stack conventions. Everything that varies between projects lives in `.devflow.yaml` or in the project's own specialist agents.

See [`docs/devflow-plugin-plan.md`](docs/devflow-plugin-plan.md) for full architecture rationale.
