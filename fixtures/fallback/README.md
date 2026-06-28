# Fixture: fallback (generic)

Tests that the motor correctly falls back to the generic agent when no specialist is found.

This fixture has no `.claude/agents/` directory anywhere — intentionally. When the motor runs
`discover-specialists.sh` against any path here, it finds nothing and must apply the fallback.

With `fallback.mode: generic`, the motor should proceed using `agents/generic.md` from the plugin root.
