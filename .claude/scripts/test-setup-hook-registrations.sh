#!/usr/bin/env bash
# test-setup-hook-registrations.sh — guards against the ADR-043 bug class:
# setup.sh registering a hook into consumer settings.json that the substrate
# does not actually ship (a dead, silently-non-firing registration).
#
# /doctor's hook-health check only audits core/hooks/ -> canonical-template
# registration; it does NOT see what setup.sh's jq steps inject. This test
# closes that blind spot: every `.claude/hooks/<name>.sh` that setup.sh wires
# into a consumer MUST exist in core/hooks/ (symlinked) or templates/hooks/
# (copied). Anything else is a dead registration.
set -uo pipefail
INFRA_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SETUP="$INFRA_DIR/setup.sh"
PASS=0; FAIL=0; MISSING=""

# Registration targets setup.sh references. A de-registration migration filters
# by bare hook name (jq test("name")) and does NOT name a `.claude/hooks/<name>.sh`
# path, so retired hooks correctly drop out of this set.
TARGETS=$(grep -oE '\.claude/hooks/[a-zA-Z0-9_-]+\.sh' "$SETUP" 2>/dev/null | sed 's#\.claude/hooks/##' | sort -u)

for h in $TARGETS; do
  if [ -f "$INFRA_DIR/core/hooks/$h" ] || [ -f "$INFRA_DIR/templates/hooks/$h" ]; then
    PASS=$((PASS+1)); echo "  PASS: $h ships (core/hooks or templates/hooks)"
  else
    FAIL=$((FAIL+1)); MISSING="$MISSING $h"; echo "  FAIL: $h registered by setup.sh but NOT shipped (dead registration)"
  fi
done

echo "=== test-setup-hook-registrations: PASS=$PASS FAIL=$FAIL ==="
[ -n "$MISSING" ] && echo "DEAD REGISTRATIONS:$MISSING"
[ "$FAIL" -eq 0 ]
