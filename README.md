# DevFlow

[![CI](https://github.com/lennoncastro/dev-flow/actions/workflows/ci.yml/badge.svg)](https://github.com/lennoncastro/dev-flow/actions/workflows/ci.yml)

A Claude Code plugin that packages a complete AI-assisted development workflow. Stack-agnostic: the motor orchestrates; each project brings its own stack conventions via `.claude/agents/` specialists.

## Quick start

```
claude plugin install lennoncastro/devflow
cd your-project && /devflow init
/devflow start "add dark mode to settings screen"
```

## Subcommands

| Category | Command | Description |
|---|---|---|
| Workflow | `init` | Set up DevFlow in current project |
| | `start <task>` | Run full AI workflow for a task |
| | `plan <task>` | Plan only, no execution |
| | `queue <t1> && <t2>` | Run tasks in sequence |
| | `retry [run-id]` | Retry from last failed phase |
| | `pause [run-id]` | Pause a run after current phase |
| | `resume [run-id]` | Resume a paused run |
| | `abort [run-id]` | Cancel and clean up a run |
| Observability | `status [--watch]` | Show active/recent runs |
| | `logs [run-id]` | Timeline of phases for a run |
| | `history` | All runs with filters |
| | `diff [run-id]` | Show worktree diff before PR |
| | `open [run-id]` | Open run's PR in browser |
| Maintenance | `clean` | Remove stale worktrees |
| | `rollback [run-id]` | Revert a run's changes |
| | `gc [--older-than=Nd]` | Delete old telemetry files |
| | `update` | Sync plugin to latest version |
| Config | `config` | Interactive config wizard |
| | `config show` | Display current config values |
| Specialists | `specialist add` | Create a new specialist agent |
| | `specialist validate` | Lint all specialist files |
| Diagnostics | `doctor` | Check setup health |

## Fixing bugs

Same command — the specialist knows how to debug:

    /devflow start "fix: dashboard crashes when user has no transactions"

The specialist's `## Debugging` section tells the motor to reproduce the bug and write a failing test before touching production code. Stack-specific: Flutter uses `flutter run`, Python uses `pytest -xvs`, etc.

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
```

Full reference: [`docs/devflow-schema.md`](docs/devflow-schema.md).

## How specialists work

The motor discovers `.claude/agents/` files by walking upward from each task-touched path — no declaration needed in config, placement is the routing signal. Run `/devflow specialist add` to create one from templates for 9 stacks, each including a `## Debugging` section with stack-specific investigation guidance.

See [`docs/specialist-contract.md`](docs/specialist-contract.md) for the full format spec.

## Contributing

**Golden rule: nothing project-specific in hooks.**

The motor must have zero hardcoded branches, commands, models, or stack conventions. Everything that varies between projects lives in `.devflow.yaml` or in the project's own specialist agents.

See [`docs/devflow-plugin-plan.md`](docs/devflow-plugin-plan.md) for full architecture rationale.
