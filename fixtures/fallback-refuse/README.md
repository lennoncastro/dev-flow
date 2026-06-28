# Fixture: fallback-refuse

Tests that the motor stops and requests a specialist when none is found and `fallback.mode: refuse`.

This fixture has no `.claude/agents/` directory anywhere — intentionally. With `fallback.mode: refuse`,
the motor must not proceed with a generic agent. It should halt and tell the user to create a
specialist in `.claude/agents/` for the relevant scope before retrying.
