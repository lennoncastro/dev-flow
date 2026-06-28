#!/usr/bin/env bash
set -euo pipefail

SKILL="skills/devflow/SKILL.md"
FAIL=0

fail() { echo "FAIL: $1"; FAIL=1; }
pass() { echo "OK:   $1"; }

# 1. File exists
if [ ! -f "$SKILL" ]; then
  fail "SKILL.md not found at $SKILL"
  exit 1
fi
pass "SKILL.md exists"

# 2. No conflict markers
if grep -qE '^(<<<<<<<|=======|>>>>>>>)' "$SKILL"; then
  fail "conflict markers found in SKILL.md"
else
  pass "no conflict markers"
fi

# 3. Frontmatter has name: and description:
if ! head -10 "$SKILL" | grep -q '^name:'; then
  fail "frontmatter missing 'name:'"
else
  pass "frontmatter has name:"
fi
if ! head -10 "$SKILL" | grep -q '^description:'; then
  fail "frontmatter missing 'description:'"
else
  pass "frontmatter has description:"
fi

# 4. Unknown subcommand guard exists
GUARD_LINE=$(grep "If \`\$SUBCMD\` is not" "$SKILL" | head -1 || true)
if [ -z "$GUARD_LINE" ]; then
  fail "Unknown subcommand guard line not found"
else
  pass "Unknown subcommand guard found"
  # Check all known subcommands appear in guard
  KNOWN="init start plan queue retry pause resume abort status logs open diff history config specialist doctor clean rollback update gc"
  for sub in $KNOWN; do
    if ! echo "$GUARD_LINE" | grep -q "\`${sub}\`"; then
      fail "subcommand '$sub' missing from Unknown subcommand guard"
    fi
  done
  pass "all subcommands present in Unknown subcommand guard"
fi

# 5. Each implemented subcommand has a ## Subcommand: section
# (clean and rollback are listed in guard but are stubs — skip them)
IMPLEMENTED="init start plan queue retry pause resume abort status logs open diff history config specialist doctor update gc"
for sub in $IMPLEMENTED; do
  if ! grep -q "^## Subcommand: ${sub}" "$SKILL"; then
    fail "missing '## Subcommand: ${sub}' section"
  fi
done
pass "all implemented subcommand sections present"

exit $FAIL
