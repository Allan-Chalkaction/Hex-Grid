#!/usr/bin/env bash
# test-drift-lint.sh — seeded-violation fixtures for drift-lint.sh (ADR-080 D4).
#
# Builds a fixture tree in a tempdir with each drift class seeded, runs
# `drift-lint.sh --root <fixture>`, and asserts the expected FAIL/WARN/PASS.
# NEVER mutates the real repo. Also runs drift-lint against the real repo and
# asserts it PASSes (the substrate must be clean).
#
# Exit 0: all assertions passed. Exit 1: at least one failed.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
LINT="${REPO_ROOT}/core/scripts/drift-lint.sh"

if [ ! -f "$LINT" ]; then
  echo "ERROR: drift-lint.sh not found at $LINT" >&2
  exit 2
fi

echo "=== test-drift-lint.sh ==="
echo "LINT: $LINT"
echo

total=0
failures=0

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  total=$((total + 1))
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    echo "PASS: $name"
  else
    failures=$((failures + 1))
    echo "FAIL: $name — expected output to contain: $needle"
  fi
}

assert_rc() {
  local name="$1" got="$2" want="$3"
  total=$((total + 1))
  if [ "$got" = "$want" ]; then
    echo "PASS: $name (rc=$got)"
  else
    failures=$((failures + 1))
    echo "FAIL: $name — rc=$got, expected $want"
  fi
}

# ---------------------------------------------------------------------------
# Fixture A: a CLEAN tree (minimal valid substrate) -> PASS, rc 0.
# ---------------------------------------------------------------------------
FIX_CLEAN=$(mktemp -d)
trap 'rm -rf "$FIX_CLEAN" "${FIX_VIOL:-}"' EXIT
mkdir -p "$FIX_CLEAN/core/hooks" "$FIX_CLEAN/core/rules" "$FIX_CLEAN/core/agents" "$FIX_CLEAN/core/config/global" "$FIX_CLEAN/docs"
# a registered hook
cat > "$FIX_CLEAN/core/hooks/my-hook.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FIX_CLEAN/core/config/global/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[{"hooks":[{"command":".claude/hooks/my-hook.sh"}]}]}}
EOF
# an agent with a valid model pin
cat > "$FIX_CLEAN/core/agents/good.md" <<'EOF'
---
name: good
model: sonnet
---
ok
EOF
# a rule citing an existing core/ path
cat > "$FIX_CLEAN/core/rules/r.md" <<'EOF'
See `core/hooks/my-hook.sh` for details.
EOF

CLEAN_OUT=$(bash "$LINT" --root "$FIX_CLEAN" 2>&1); CLEAN_RC=$?
assert_rc "clean fixture exits 0" "$CLEAN_RC" "0"
assert_contains "clean fixture reports PASS" "$CLEAN_OUT" "DRIFT-LINT: PASS"

# ---------------------------------------------------------------------------
# Fixture B: a VIOLATING tree seeding each FAIL + WARN class.
# ---------------------------------------------------------------------------
FIX_VIOL=$(mktemp -d)
mkdir -p "$FIX_VIOL/core/hooks" "$FIX_VIOL/core/rules" "$FIX_VIOL/core/agents" "$FIX_VIOL/core/config/global" "$FIX_VIOL/docs"

# (1) self-referential symlink: points back inside the repo.
echo "real" > "$FIX_VIOL/core/rules/real-target.md"
ln -s "$FIX_VIOL/core/rules/real-target.md" "$FIX_VIOL/core/rules/self-link.md"
# (1) broken symlink.
ln -s "/nonexistent/path/xyz" "$FIX_VIOL/docs/broken-link.md"

# (2a) unregistered hook (not allowlisted).
cat > "$FIX_VIOL/core/hooks/orphan-hook.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# (2b) settings registers a hook with no backing file -> dead reference.
cat > "$FIX_VIOL/core/config/global/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[{"hooks":[{"command":".claude/hooks/ghost-hook.sh"}]}]}}
EOF

# (5) rule cites a nonexistent core/ path.
cat > "$FIX_VIOL/core/rules/bad-ref.md" <<'EOF'
The contract lives in `core/rules/does-not-exist.md`.
EOF

# (6) agent with a disallowed model pin.
cat > "$FIX_VIOL/core/agents/bad.md" <<'EOF'
---
name: bad
model: gpt-4o
---
nope
EOF

# (3) stale delete-after marker (WARN).
cat > "$FIX_VIOL/core/rules/marker.md" <<'EOF'
This block is temporary; delete after the cutover lands.
EOF

# (4) dead track arm without dormant-by-design annotation (WARN).
cat > "$FIX_VIOL/core/hooks/track-hook.sh" <<'EOF'
#!/usr/bin/env bash
case "$TRACK" in
  pipeline)
    echo blocked
    ;;
esac
EOF

VIOL_OUT=$(bash "$LINT" --root "$FIX_VIOL" 2>&1); VIOL_RC=$?

assert_rc "violating fixture exits 1" "$VIOL_RC" "1"
assert_contains "self-link detected" "$VIOL_OUT" "self-referential symlink"
assert_contains "broken-link detected" "$VIOL_OUT" "broken symlink"
assert_contains "unregistered hook detected" "$VIOL_OUT" "orphan-hook.sh"
assert_contains "dead hook reference detected" "$VIOL_OUT" "ghost-hook.sh"
assert_contains "bad rule reference detected" "$VIOL_OUT" "does-not-exist.md"
assert_contains "bad model pin detected" "$VIOL_OUT" "gpt-4o"
assert_contains "stale marker WARN" "$VIOL_OUT" "stale-marker candidate"
assert_contains "dead track arm WARN" "$VIOL_OUT" "lacks a dormant-by-design annotation"
assert_contains "violating fixture summary is FAIL" "$VIOL_OUT" "DRIFT-LINT: FAIL"

# ---------------------------------------------------------------------------
# Fixture C: the REAL repo must pass clean.
# ---------------------------------------------------------------------------
REAL_OUT=$(bash "$LINT" 2>&1); REAL_RC=$?
assert_rc "real repo exits 0" "$REAL_RC" "0"
assert_contains "real repo reports PASS" "$REAL_OUT" "DRIFT-LINT: PASS"

echo
echo "=== Summary: $((total - failures))/${total} passed ==="
if [ "$failures" -gt 0 ]; then
  exit 1
fi
exit 0
