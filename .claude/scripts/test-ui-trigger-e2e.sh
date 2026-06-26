#!/usr/bin/env bash
# BINDING Definition-of-Done harness for the ui-spec-trigger fix (ADR-104, W3/UST-T8).
#
# The STAT's DoD: prove a UI-touching wave fires ui-spec AND adds ui-review AND lands the UI change.
# A full live /orchestrated run (real cto/architect/pm-spec/ui-spec/implementer/ui-review agents authoring a
# real .tsx) is non-deterministic, multi-minute, and needs a UI app — impractical as a repeatable test. So
# this harness proves the previously-SILENTLY-BROKEN part DETERMINISTICALLY end-to-end: a wave SPEC FILE →
# wave-manifest.py parse → the dispatch decision the /orchestrated SKILL+engine make → ui-spec dispatched +
# ui-review in the gate set. The live-agent leg (ui-spec addendum text authored, .tsx written by the
# implementer) is the operator's final acceptance — the documented procedure at the bottom of this file.
#
# It exercises the REAL orchestrated.js predicate (extracted) + the REAL wave-manifest.py parse, and a
# DRIFT-GUARD asserts the engine's actual wantUi / ui-review-gate-add wiring expressions are present (so the
# decision this harness simulates stays bound to the shipping code). Exit 0 = all PASS; exit 1 = a FAIL.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ORCH="${REPO_ROOT}/core/scripts/workflows/orchestrated.js"
WM="${REPO_ROOT}/core/scripts/wave-manifest.py"
for f in "$ORCH" "$WM"; do [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }; done

PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }
SCRATCH=$(mktemp -d); trap "rm -rf '$SCRATCH'" EXIT

# --- DRIFT GUARD: the engine's real wiring expressions must exist (bind this harness to shipping code) ----
if grep -q 'const wantUi = _a.ui === true || _a.hasUi === true || hasUiSurface(_a.tickets)' "$ORCH"; then
  ok "engine wiring: wantUi = _a.ui || _a.hasUi || hasUiSurface(_a.tickets) [ui-spec dispatch]"
else
  ko "wantUi wiring" "the ui-spec dispatch wiring expression drifted in orchestrated.js"
fi
if grep -q "gateReviewers.push('ui-review')" "$ORCH" && grep -q 'const uiSurface = hasUiSurface(tickets)' "$ORCH"; then
  ok "engine wiring: ui-review auto-added to gateReviewers on hasUiSurface(tickets) [visual gate]"
else
  ko "ui-review gate wiring" "the ui-review gate-add wiring drifted in orchestrated.js"
fi

# --- decide(specFile) → echoes "hasUi=<bool> wantUi=<bool> uiReview=<bool>" using the REAL parse+predicate --
decide() {
  local spec="$1" manifest="$SCRATCH/m.json"
  python3 "$WM" write-from-plan "$spec" "$manifest" >/dev/null 2>&1 || { echo "PARSE_FAIL"; return; }
  node - "$ORCH" "$manifest" <<'NODE'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const manifest = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
function extract(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('predicate not found in orchestrated.js: ' + name);
  // NB: naive brace-matcher — safe only while these predicate bodies contain no brace inside a
  // string/template-literal/regex/comment (true today; see ADR-104 lockstep note if that changes).
  let depth = 0, started = false;
  for (let j = src.indexOf('{', start); j < src.length; j++) {
    if (src[j] === '{') { depth++; started = true; }
    else if (src[j] === '}') { depth--; if (started && depth === 0) return src.slice(start, j + 1); }
  }
  throw new Error('extract failed: ' + name);
}
eval(extract('normalizePlannedPath') + '\n' + extract('isUiSurfacePath') + '\n' + extract('hasUiSurface'));
// Simulate the /orchestrated SKILL ingest: tickets + hasUi come from the manifest (the real handoff carry).
const tickets = (manifest.tickets || []).map(t => ({ key: t.key, planned_files: t.planned_files || [] }));
const _a = { ui: false, hasUi: !!manifest.has_ui, tickets };   // SKILL passes ui:absent(false) + hasUi from carry
// The REAL engine expressions (kept bound to shipping code by the drift-guard above):
const wantUi = _a.ui === true || _a.hasUi === true || hasUiSurface(_a.tickets);   // ui-spec dispatch
const uiReview = hasUiSurface(tickets);                                           // ui-review gate-add
console.log(`hasUi=${!!manifest.has_ui} wantUi=${wantUi} uiReview=${uiReview}`);
NODE
}

# --- Stage A: a UI-touching fixture wave (as roadmap would emit: **Has UI:** true + a .tsx planned_file) ----
cat > "$SCRATCH/ui-wave.md" <<'EOF'
# Wave: wave-ui-fixture
**Protocol version:** 3
**Has UI:** true

## Tickets

### UF-T1: render the settings panel
- depends_on: []
- planned_files: [src/components/SettingsPanel.tsx]
- acceptance: [AC-1]
- gate_recommendations: [code-reviewer]
- manual_review_required: true
- description: |
    Add a settings panel component.
EOF
res=$(decide "$SCRATCH/ui-wave.md")
if [ "$res" = "hasUi=true wantUi=true uiReview=true" ]; then
  ok "UI wave end-to-end: spec(.tsx) → manifest has_ui=true → ui-spec FIRES + ui-review GATE added"
else
  ko "UI wave e2e" "expected 'hasUi=true wantUi=true uiReview=true', got '$res'"
fi

# --- Stage B: the dogfood NEGATIVE — this epic's own infra wave must NOT trigger the visual path ----
cat > "$SCRATCH/infra-wave.md" <<'EOF'
# Wave: wave-infra-fixture
**Protocol version:** 3

## Tickets

### IF-T1: deterministic detection
- depends_on: []
- planned_files: [core/scripts/workflows/orchestrated.js]
- acceptance: [AC-2]
- gate_recommendations: [code-reviewer]
- manual_review_required: true
- description: |
    Add the predicate.
EOF
res=$(decide "$SCRATCH/infra-wave.md")
if [ "$res" = "hasUi=false wantUi=false uiReview=false" ]; then
  ok "infra wave (dogfood): spec(.js) → has_ui=false → ui-spec SKIPPED + no ui-review (correct: zero UI)"
else
  ko "infra wave e2e" "expected 'hasUi=false wantUi=false uiReview=false', got '$res'"
fi

# --- Stage C: the silent-skip regression — a .tsx wave with NO carry header still fires (deterministic floor) -
cat > "$SCRATCH/nocarry-wave.md" <<'EOF'
# Wave: wave-nocarry
**Protocol version:** 3

## Tickets

### NC-T1: a hand-rolled UI ticket with no Has-UI header
- depends_on: []
- planned_files: [src/Widget.tsx]
- acceptance: [AC-3]
- gate_recommendations: [code-reviewer]
- manual_review_required: true
- description: |
    Hand-authored wave, no **Has UI:** header (e.g. an ad-hoc /orchestrated dispatch).
EOF
res=$(decide "$SCRATCH/nocarry-wave.md")
# has_ui carry is false (no header), but the deterministic floor over the .tsx planned_file still fires both.
if [ "$res" = "hasUi=false wantUi=true uiReview=true" ]; then
  ok "no-carry .tsx wave: deterministic floor STILL fires ui-spec + ui-review (the silent-skip regression)"
else
  ko "no-carry floor" "expected 'hasUi=false wantUi=true uiReview=true', got '$res'"
fi

echo ""
echo "============================================"
echo "TOTAL: $((PASS+FAIL)) — PASS: $PASS, FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then echo -e "FAILURES:$FAIL_DETAIL"; exit 1; fi
echo "ALL GREEN"
cat <<'NOTE'

--- LIVE-ACCEPTANCE PROCEDURE (operator, the live-agent leg of the DoD) ---
The harness above proves the decision/wiring deterministically. To close the binding DoD's live leg,
run a real UI wave once through /orchestrated in a repo that HAS a UI surface and confirm in the run:
  1. the ui-spec phase ran and persisted a ui-spec-addendum (payload.uiSpec non-null);
  2. 'ui-review' appears in payload.gateReviewers and the ui-review agent ran at batch-gate;
  3. the .tsx/.jsx change actually landed in the wave commit.
Record the run folder + the three confirmations in the epic run-log. (claude-infra itself has no UI app,
so the live leg is validated in a consumer/app repo — this harness is the substrate-side proof.)
NOTE
exit 0
