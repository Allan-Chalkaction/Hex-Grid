#!/usr/bin/env bash
# test-infra-doctor.sh — structural smoke test for infra-doctor.sh.
#
# Verifies the diagnostic engine RUNS and emits its contract (4 sections + a
# parseable DOCTOR VERDICT line). It does NOT assert the repo is healthy — the
# engine surfaces real issues/warnings, which vary; this test asserts the
# engine's structure and safety properties (read-only, recursion-guarded).
#
# NOTE: infra-doctor.sh runs the full test-*.sh suite (minus this file), so this
# smoke test transitively re-runs them. Kept lightweight by asserting structure,
# not by re-parsing every nested result.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT" || exit 2

PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

ENGINE="core/scripts/infra-doctor.sh"

echo "test-infra-doctor: structural smoke test"

# 1. Engine exists and is executable.
if [ -x "$ENGINE" ]; then ok "infra-doctor.sh exists and is executable"; else ko "engine missing/not executable" "$ENGINE"; fi

# 2. Runs and exits 0 in non-strict mode (a diagnostic never fails the session).
OUT="$(bash "$ENGINE" --quiet 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "non-strict run exits 0 (rc=$RC)"; else ko "non-strict run should exit 0" "rc=$RC"; fi

# 3. Emits all four section headers.
for sec in \
  "1. Synthetic test suite" \
  "2. Hook health" \
  "3. ADR<->rules pairing" \
  "4. Consumer distribution"; do
  if printf '%s' "$OUT" | grep -qF "$sec"; then ok "section present: $sec"; else ko "missing section" "$sec"; fi
done

# 4. Emits a parseable verdict line in the closed vocabulary.
if printf '%s' "$OUT" | grep -qE '^DOCTOR VERDICT: (HEALTHY|WARNINGS \([0-9]+\)|ISSUES \([0-9]+\), WARNINGS \([0-9]+\))$'; then
  ok "DOCTOR VERDICT line present and well-formed"
else
  ko "verdict line missing/malformed" "$(printf '%s' "$OUT" | grep 'DOCTOR VERDICT' || echo '(none)')"
fi

# 5. Recursion guard — the engine must NOT run its own test (no nested invocation).
if printf '%s' "$OUT" | grep -qE 'PASS:[[:space:]]+test-infra-doctor\.sh|ISSUE:[[:space:]]+test-infra-doctor\.sh'; then
  ko "recursion guard broken" "engine ran test-infra-doctor.sh (infinite-recursion risk)"
else
  ok "recursion guard intact (engine excludes its own test)"
fi

# 6. Unknown flag rejected with exit 2 (arg hygiene).
bash "$ENGINE" --bogus-flag >/dev/null 2>&1; RC2=$?
if [ "$RC2" -eq 2 ]; then ok "unknown flag exits 2"; else ko "unknown flag should exit 2" "rc=$RC2"; fi

# 7. --strict is accepted (exits 0 when healthy, 1 when issues; never 2/crash).
bash "$ENGINE" --strict --quiet >/dev/null 2>&1; RC3=$?
if [ "$RC3" -eq 0 ] || [ "$RC3" -eq 1 ]; then ok "--strict accepted (rc=$RC3 ∈ {0,1})"; else ko "--strict crashed" "rc=$RC3"; fi

echo ""
echo "============================================"
echo "TOTAL: $((PASS+FAIL)) — PASS: $PASS, FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then echo "ALL GREEN"; exit 0; else echo "FAILURES present"; exit 1; fi
