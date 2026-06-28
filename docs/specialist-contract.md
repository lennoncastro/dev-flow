---
title: DevFlow — Specialist Contract
status: draft
---

# Specialist Contract

A DevFlow specialist is a Claude Code subagent placed by the project in `.claude/agents/<name>.md`. The motor discovers it; the project owns its content.

## Format

```markdown
---
name: <slug>           # required — unique identifier within the project
description: <string>  # required — one line, used by the motor to log routing decisions
---

<agent instructions>
```

No other frontmatter fields are required. Additional fields are ignored by the motor.

## Agent body

The body is free-form instructions for the specialist's domain. It should cover:

- Code style and idioms for the stack
- Libraries and patterns to prefer or avoid
- Testing approach (framework, structure, what to cover)
- Any stack-specific constraints or conventions

The body must **not** include orchestration logic. Do not write instructions about creating worktrees, committing, pushing, or opening PRs — those are the motor's responsibility, not the specialist's.

## Discovery rules

The motor walks upward from each path the task touches, collecting `.claude/agents/*.md` files at each level. The most specific (deepest) `.claude/agents/` directory wins for a given scope.

```
# Single-stack — one specialist at repo root covers everything
.claude/
  agents/
    backend.md

# Monorepo — each area has its own specialist
apps/
  api/
    .claude/
      agents/
        backend.md     ← wins for paths under apps/api/
  web/
    .claude/
      agents/
        frontend.md    ← wins for paths under apps/web/
```

## Routing cases

| Scopes touched | Result |
|---|---|
| One | Specialist for that scope is invoked |
| Multiple (monorepo) | Fan-out — one agent per scope, capped by `fan_out.max_agents` |
| None found | `fallback` config applies (`generic` or `refuse`) |

## Constraints

- No hardcoded branch names, model names, or deploy commands.
- No orchestration logic of any kind.
- Specialists own conventions; the motor owns the workflow.
