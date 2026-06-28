# Fixture: monorepo

Tests the DevFlow motor against a monorepo with three independent scopes.

## Structure

- `apps/api/` — Node.js/Express backend with its own specialist
- `apps/web/` — React/TypeScript frontend with its own specialist
- `packages/shared/` — shared library with its own specialist

## What this exercises

- Specialist discovery by directory proximity (deepest `.claude/agents/` wins per scope)
- Fan-out: motor spawns up to 3 agents in parallel, one per scope
- `on_partial_failure: isolate` — a failing scope is marked and skipped, others continue
- Fallback to generic for any path not covered by a specialist
