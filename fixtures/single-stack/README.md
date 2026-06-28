# DevFlow fixture — single-stack

Minimal fixture for testing the DevFlow motor on a single-stack project.

## What it covers

- Config validation (`.devflow.yaml`)
- Worktree creation from `base_branch`
- Specialist discovery (`.claude/agents/specialist.md` at repo root)
- Motor cycle: test → review → PR
- Telemetry output to `.devflow/runs/`

## Structure

```
fixtures/single-stack/
├── .devflow.yaml           # Motor config (fan_out disabled, generic fallback)
├── .claude/
│   └── agents/
│       └── specialist.md  # TypeScript specialist — illustrates the format
└── README.md
```

## Usage

Run `/devflow start <task>` from this directory with the DevFlow plugin installed.
