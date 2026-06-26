#!/usr/bin/env bash
# VPH-W4A / ADR-116 D1 half-b — regression test for the PLANNED-path ADR-finalize.
#
# The round-trip fixture that would have caught CR-001/002/003: it simulates half-a → half-b
# (stage a Draft adr.md, run the finalize logic) and asserts the canonical docs/decisions ADR
# lands Accepted, numbered, with a non-(Draft) title — and is NOT left an empty Proposed stub.
#
# The finalize logic under test is the PLANNED-path block in core/skills/orchestrated/SKILL.md.
# Rather than re-extract it from markdown (fragile), this test reproduces the exact shell the
# skill documents and exercises it against the REAL core/scripts/claim-id.py in a sandbox — so a
# regression in claim-id's stdout contract OR the parse/rewrite logic fails the test.
#
# Tests:
#   test_finalize_roundtrip   — Draft adr.md → canonical ADR-NNN-<epic>.md Accepted, numbered title (CR-001/002/003)
#   test_canonical_not_stub   — the canonical file is NOT left the empty `**Status:** Proposed` stub (CR-003)
#   test_epic_slug_in_title   — claim + title use the EPIC slug, not the wave slug (CR-004)
#   test_idempotent_second_wave — a second wave (no Draft at epic root) no-ops, claims no second number (CR-004)
#   test_skill_grep_contract  — the SKILL.md block carries the CR-001 parse + CR-003 canonical-write wiring
#
# Usage:   bash core/scripts/test-w4-adr-finalize.sh
# Exit:    0 — all PASS; N — N failures (FAIL: messages on stdout)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLAIM_ID="${REPO_ROOT}/core/scripts/claim-id.py"
SKILL="${REPO_ROOT}/core/skills/orchestrated/SKILL.md"

# ---------------------------------------------------------------------------
# The finalize logic under test — a faithful reproduction of the PLANNED-path
# block in orchestrated/SKILL.md (CR-001/002/003/004). $S, $D, $EPIC_ROOT are
# the inputs the skill computes; here the sandbox supplies them.
# ---------------------------------------------------------------------------
run_finalize() {
  local S="$1" D="$2" EPIC_ROOT="$3"
  local EPIC_SLUG ADR_DRAFT CLAIM_OUT ADR_NUM ADR_PATH
  EPIC_SLUG=$(basename "$EPIC_ROOT")          # CR-004: epic slug, not wave slug
  ADR_DRAFT="$EPIC_ROOT/adr.md"
  if [ -f "$ADR_DRAFT" ] && grep -qE '^\*\*Status:\*\*[[:space:]]*Draft' "$ADR_DRAFT"; then
    CLAIM_OUT=$(python3 "$S/claim-id.py" adr "$EPIC_SLUG")            # CR-001: capture once
    ADR_NUM=$(printf '%s' "$CLAIM_OUT" | sed -n 's/^CLAIM-ADR: number=\([0-9]\{3,4\}\).*/\1/p')
    ADR_PATH=$(printf '%s' "$CLAIM_OUT" | sed -n 's/^CLAIM-ADR: .*path=\(.*\)$/\1/p')
    if [ -z "$ADR_NUM" ] || [ -z "$ADR_PATH" ]; then
      echo "ERROR: could not parse claim-id output: '$CLAIM_OUT'" >&2; return 1
    fi
    cp "$ADR_DRAFT" "$D/adr.md"                                        # CR-003: run-folder copy
    mv -f "$ADR_DRAFT" "$ADR_PATH"                                     # CR-003: into canonical stub
    python3 - "$ADR_PATH" "ADR-$ADR_NUM" "$EPIC_SLUG" <<'PY'
import sys, re
path, num, slug = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as f: t = f.read()
t = re.sub(r'^# ADR \(Draft\)(.*)$', f'# {num} — {slug}', t, count=1, flags=re.M)   # CR-002: no dead \b
t = re.sub(r'^\*\*Status:\*\*[ \t]*Draft.*$', f'**Status:** Accepted ({num}, finalized at /orchestrated build-start — ADR-116 D1 half-b)', t, count=1, flags=re.M)
with open(path, "w", encoding="utf-8") as f: f.write(t)
PY
    # Echo the parsed facts so the harness can assert them.
    echo "FINALIZE_OK num=$ADR_NUM path=$ADR_PATH"
  else
    echo "FINALIZE_NOOP"
  fi
}

# ---------------------------------------------------------------------------
# Sandbox — stage a Draft adr.md at an epic root + an empty docs/decisions/.
# ---------------------------------------------------------------------------
setup_sandbox() {
  local sb; sb=$(mktemp -d -t adr-116-w4-XXXXXX)
  mkdir -p "${sb}/core/scripts" \
           "${sb}/docs/decisions" \
           "${sb}/docs/step-3-specs/v2-pipeline-hardening/waves/wave-4-handoff-adr" \
           "${sb}/run"
  # Real claim-id.py so the stdout contract + stub-write behavior are exercised, not mocked.
  cp "$CLAIM_ID" "${sb}/core/scripts/claim-id.py"
  # Half-a output: a Draft, UNnumbered, decision-bearing adr.md at the EPIC ROOT.
  cat > "${sb}/docs/step-3-specs/v2-pipeline-hardening/adr.md" <<'DRAFT'
# ADR (Draft) — v2-pipeline-hardening

**Status:** Draft
**Date:** 2026-06-17

## Decisions (pre-filled from the resolved forks)

### D-1: stage-at-lock → finalize-at-build

_(resolved at /roadmap lock from the funnel.)_
DRAFT
  printf '%s' "$sb"
}

# ---------------------------------------------------------------------------
# TESTS
# ---------------------------------------------------------------------------

test_finalize_roundtrip() {
  local sb; sb=$(setup_sandbox)
  local out
  out=$( cd "$sb" && run_finalize "core/scripts" "run" "docs/step-3-specs/v2-pipeline-hardening" )
  if ! printf '%s' "$out" | grep -q '^FINALIZE_OK '; then
    echo "FAIL: test_finalize_roundtrip — finalize did not fire; got: ${out}"; rm -rf "$sb"; return 1
  fi
  local num path
  num=$(printf '%s' "$out" | sed -n 's/^FINALIZE_OK num=\([0-9]*\).*/\1/p')
  path=$(printf '%s' "$out" | sed -n 's/^FINALIZE_OK .*path=\(.*\)$/\1/p')
  # CR-001: number must be a bare 3-4 digit string, NOT the whole `CLAIM-ADR:` line.
  if ! printf '%s' "$num" | grep -qE '^[0-9]{3,4}$'; then
    echo "FAIL: test_finalize_roundtrip — ADR_NUM not parsed to a bare number (CR-001), got '${num}'"; rm -rf "$sb"; return 1
  fi
  # CR-003: the canonical file exists at the parsed path.
  if [ ! -f "${sb}/${path}" ]; then
    echo "FAIL: test_finalize_roundtrip — canonical ADR file missing at ${path} (CR-003)"; rm -rf "$sb"; return 1
  fi
  # Expected canonical name: docs/decisions/ADR-NNN-v2-pipeline-hardening.md
  case "$path" in
    docs/decisions/ADR-${num}-v2-pipeline-hardening.md) : ;;
    *) echo "FAIL: test_finalize_roundtrip — unexpected canonical path '${path}' (CR-003/004)"; rm -rf "$sb"; return 1;;
  esac
  # CR-003: canonical file is Accepted with the claimed number.
  if ! grep -qE "^\*\*Status:\*\* Accepted \(ADR-${num}," "${sb}/${path}"; then
    echo "FAIL: test_finalize_roundtrip — canonical not marked Accepted with ADR-${num}"; rm -rf "$sb"; return 1
  fi
  # CR-002: title rewritten to `# ADR-NNN — <slug>`, no longer `(Draft)`.
  if ! grep -qE "^# ADR-${num} — v2-pipeline-hardening$" "${sb}/${path}"; then
    echo "FAIL: test_finalize_roundtrip — title not rewritten to '# ADR-${num} — v2-pipeline-hardening' (CR-002)"; rm -rf "$sb"; return 1
  fi
  if grep -q '(Draft)' "${sb}/${path}"; then
    echo "FAIL: test_finalize_roundtrip — title still carries '(Draft)' (CR-002 dead regex)"; rm -rf "$sb"; return 1
  fi
  # The decision blocks travelled into the canonical ADR (CR-005 content survives).
  if ! grep -q '### D-1: stage-at-lock' "${sb}/${path}"; then
    echo "FAIL: test_finalize_roundtrip — resolved-fork decision block did not survive into the ADR (CR-005)"; rm -rf "$sb"; return 1
  fi
  # Run-folder copy exists for the implementer.
  if [ ! -f "${sb}/run/adr.md" ]; then
    echo "FAIL: test_finalize_roundtrip — run-folder copy run/adr.md missing"; rm -rf "$sb"; return 1
  fi
  rm -rf "$sb"; echo "PASS: test_finalize_roundtrip"; return 0
}

test_canonical_not_stub() {
  local sb; sb=$(setup_sandbox)
  local out path
  out=$( cd "$sb" && run_finalize "core/scripts" "run" "docs/step-3-specs/v2-pipeline-hardening" )
  path=$(printf '%s' "$out" | sed -n 's/^FINALIZE_OK .*path=\(.*\)$/\1/p')
  # CR-003: the canonical file MUST NOT be left the claim-id `**Status:** Proposed` stub.
  if grep -qE '^\*\*Status:\*\* Proposed' "${sb}/${path}"; then
    echo "FAIL: test_canonical_not_stub — canonical left as empty Proposed stub (CR-003 core bug)"; rm -rf "$sb"; return 1
  fi
  # And it must not still contain the stub's tell-tale "MUST be overwritten" stub language.
  if grep -q 'MUST be overwritten' "${sb}/${path}"; then
    echo "FAIL: test_canonical_not_stub — stub body survived (canonical content not written, CR-003)"; rm -rf "$sb"; return 1
  fi
  rm -rf "$sb"; echo "PASS: test_canonical_not_stub"; return 0
}

test_epic_slug_in_title() {
  local sb; sb=$(setup_sandbox)
  local out path
  out=$( cd "$sb" && run_finalize "core/scripts" "run" "docs/step-3-specs/v2-pipeline-hardening" )
  path=$(printf '%s' "$out" | sed -n 's/^FINALIZE_OK .*path=\(.*\)$/\1/p')
  # CR-004: epic slug (v2-pipeline-hardening), NOT the wave slug (wave-4-handoff-adr).
  if grep -q 'wave-4-handoff-adr' "${sb}/${path}"; then
    echo "FAIL: test_epic_slug_in_title — wave slug leaked into the ADR; expected epic slug (CR-004)"; rm -rf "$sb"; return 1
  fi
  case "$path" in
    *v2-pipeline-hardening.md) : ;;
    *) echo "FAIL: test_epic_slug_in_title — canonical not named for the epic slug: ${path} (CR-004)"; rm -rf "$sb"; return 1;;
  esac
  rm -rf "$sb"; echo "PASS: test_epic_slug_in_title"; return 0
}

test_idempotent_second_wave() {
  local sb; sb=$(setup_sandbox)
  # First wave finalizes.
  ( cd "$sb" && run_finalize "core/scripts" "run" "docs/step-3-specs/v2-pipeline-hardening" ) >/dev/null
  local before after out2
  before=$(ls "${sb}/docs/decisions"/ADR-*.md 2>/dev/null | grep -c -E 'ADR-[0-9]+-v2-pipeline-hardening\.md')
  # Second wave: the epic-root adr.md was moved away → no Draft → must no-op (claims no second number).
  out2=$( cd "$sb" && run_finalize "core/scripts" "run" "docs/step-3-specs/v2-pipeline-hardening" )
  if [ "$out2" != "FINALIZE_NOOP" ]; then
    echo "FAIL: test_idempotent_second_wave — second wave did not no-op; got: ${out2} (CR-004 idempotency)"; rm -rf "$sb"; return 1
  fi
  after=$(ls "${sb}/docs/decisions"/ADR-*.md 2>/dev/null | grep -c -E 'ADR-[0-9]+-v2-pipeline-hardening\.md')
  if [ "$before" != "$after" ] || [ "$after" != "1" ]; then
    echo "FAIL: test_idempotent_second_wave — second wave minted another ADR (before=${before} after=${after})"; rm -rf "$sb"; return 1
  fi
  rm -rf "$sb"; echo "PASS: test_idempotent_second_wave"; return 0
}

test_skill_grep_contract() {
  # The SKILL.md PLANNED-path block must carry the CR-001 parse + CR-003 canonical-write wiring,
  # so a future edit that drops them fails here too (not just in the runtime fixture).
  if ! grep -q 'CLAIM_OUT=$(python3 "$S/claim-id.py" adr "$EPIC_SLUG")' "$SKILL"; then
    echo "FAIL: test_skill_grep_contract — SKILL.md missing the single CLAIM_OUT capture (CR-001)"; return 1
  fi
  if ! grep -q 'ADR_NUM=$(printf' "$SKILL" || ! grep -q 'CLAIM-ADR: number=' "$SKILL"; then
    echo "FAIL: test_skill_grep_contract — SKILL.md missing the CLAIM-ADR number parse (CR-001)"; return 1
  fi
  if ! grep -q 'git add "$ADR_PATH" "$D/adr.md"' "$SKILL"; then
    echo "FAIL: test_skill_grep_contract — SKILL.md does not git add the canonical \$ADR_PATH (CR-003)"; return 1
  fi
  if ! grep -q 'EPIC_SLUG=$(basename "$EPIC_ROOT")' "$SKILL"; then
    echo "FAIL: test_skill_grep_contract — SKILL.md does not derive the epic slug from EPIC_ROOT (CR-004)"; return 1
  fi
  # CR-002: the title regex must NOT carry the dead \b after `(Draft)`.
  if grep -qE 'ADR \\\(Draft\\\)\\b' "$SKILL"; then
    echo "FAIL: test_skill_grep_contract — SKILL.md still has the dead '\\b' in the title regex (CR-002)"; return 1
  fi
  echo "PASS: test_skill_grep_contract"; return 0
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
failures=0
test_finalize_roundtrip     || failures=$(( failures + 1 ))
test_canonical_not_stub     || failures=$(( failures + 1 ))
test_epic_slug_in_title     || failures=$(( failures + 1 ))
test_idempotent_second_wave || failures=$(( failures + 1 ))
test_skill_grep_contract    || failures=$(( failures + 1 ))

if [ "$failures" -eq 0 ]; then
  echo ""
  echo "All 5 tests PASSED — VPH-W4A / ADR-116 D1 half-b ADR-finalize round-trip wired (CR-001..005)."
else
  echo ""
  echo "${failures} test(s) FAILED. See FAIL: messages above."
fi
exit "$failures"
