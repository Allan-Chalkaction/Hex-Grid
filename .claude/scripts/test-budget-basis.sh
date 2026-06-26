#!/usr/bin/env bash
# Synthetic test harness for the WAVE CONTEXT-BUDGET basis re-anchor (ADR-086 D1 amendment,
# planning-ergonomics Wave 1 / PEC-T1). Proves the budget basis moved from "fraction × pinned window"
# (≈600K) to the calibrated "FIXED_OVERHEAD + EFFECTIVE_TASK_CONTEXT" (≈140K) IN LOCKSTEP across the two
# active estimateWaveTokens copies, with no shared module (ADR-039) and the ADR-086 D4 WARN-only channel
# intact. The estimator is triplicated by design (orchestrated.js, roadmap.js, spec-decomposer.md doctrine);
# this harness evaluates the two JS copies directly and grep-asserts the doc copy + the WARN/channel wiring.
#
# Coverage:
#   A. Basis change: budget == FIXED_OVERHEAD + EFFECTIVE_TASK_CONTEXT (140000), NOT round(PINNED_WINDOW*0.60).
#   B. Lockstep: both estimateWaveTokens copies return identical predicted/budget/over for one fixture wave.
#   C. Over-budget fixture: over==true, evaluates to completion (no throw) — the non-blocking precondition.
#   D. No shared estimator module (ADR-039): no `import ... from ...(estimate|budget)` / `require(` for it.
#   E. nimble.js carries ONLY the doctrinal comment — no inline estimateWaveTokens definition (AC-004).
#   F. WARN-only channel intact (ADR-086 D4): budget over-branch calls warn(...), warn() hardcodes
#      criterion_match:'none' / recommended_disposition:'DISMISS', and the budget reason never reaches
#      criterionFindings (AC-006/AC-007).
#   G. No live "60% of ... window" WARN string survives in either copy (AC-005).
#   H. spec-decomposer doctrine (Step 2c) states the calibrated basis, not "0.60 × 1_000_000" (AC-002 doc arm).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"          # core/
ORCH="$ROOT/scripts/workflows/orchestrated.js"
ROADMAP="$ROOT/scripts/workflows/roadmap.js"
NIMBLE="$ROOT/scripts/workflows/nimble.js"
DECOMP="$ROOT/agents/spec-decomposer.md"
PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }

SCRATCH=$(mktemp -d)
trap "rm -rf '$SCRATCH'" EXIT

EXPECTED_BUDGET=140000   # FIXED_OVERHEAD (60000) + EFFECTIVE_TASK_CONTEXT (80000)
OLD_BUDGET=600000        # round(PINNED_WINDOW 1_000_000 * 0.60) — the DEAD basis

# --- Node evaluator: extract BUDGET_FACTORS + estimateWaveTokens from each script and run a fixture. ---
cat > "$SCRATCH/eval.js" <<'NODE'
const fs = require('fs')
// Brace-balanced extraction from a marker (estimateWaveTokens + the object literal are template-literal-free).
function extractBlock(src, marker) {
  const i = src.indexOf(marker)
  if (i < 0) throw new Error('marker not found: ' + marker)
  const open = src.indexOf('{', i)
  let depth = 0
  for (let k = open; k < src.length; k++) {
    if (src[k] === '{') depth++
    else if (src[k] === '}') { depth--; if (depth === 0) return src.slice(i, k + 1) }
  }
  throw new Error('unbalanced braces for ' + marker)
}
function loadEstimator(path) {
  const src = fs.readFileSync(path, 'utf8')
  const factors = extractBlock(src, 'const BUDGET_FACTORS = ')
  const fn = extractBlock(src, 'function estimateWaveTokens')
  // eslint-disable-next-line no-new-func
  const make = new Function(factors + '\n' + fn + '\nreturn { estimateWaveTokens, BUDGET_FACTORS };')
  return make()
}
const [orchPath, roadmapPath] = process.argv.slice(2)
const orch = loadEstimator(orchPath)
const roadmap = loadEstimator(roadmapPath)

// Fixture wave + byte map (identical inputs => identical outputs is the lockstep assertion).
const tickets = [
  { planned_files: ['a.js', 'b.js'] },
  { planned_files: ['b.js', 'c.js'] },   // b.js shared — counted once
]
const fileBytes = { 'a.js': 20000, 'b.js': 40000, 'c.js': 10000 }
const eO = orch.estimateWaveTokens(tickets, fileBytes)
const eR = roadmap.estimateWaveTokens(tickets, fileBytes)

// Over-budget fixture: many large files => predicted >> budget, must evaluate (no throw) and set over:true.
const bigTickets = Array.from({ length: 30 }, (_, i) => ({ planned_files: [`big${i}.js`] }))
const bigBytes = Object.fromEntries(bigTickets.map((t) => [t.planned_files[0], 500000]))
const big = orch.estimateWaveTokens(bigTickets, bigBytes)

console.log(JSON.stringify({
  orch: { budget: eO.budget, predicted: eO.predicted, over: eO.over,
          fixed: orch.BUDGET_FACTORS.FIXED_OVERHEAD, eff: orch.BUDGET_FACTORS.EFFECTIVE_TASK_CONTEXT },
  roadmap: { budget: eR.budget, predicted: eR.predicted, over: eR.over,
             fixed: roadmap.BUDGET_FACTORS.FIXED_OVERHEAD, eff: roadmap.BUDGET_FACTORS.EFFECTIVE_TASK_CONTEXT },
  big: { budget: big.budget, predicted: big.predicted, over: big.over },
}))
NODE

EVAL_OUT="$(node "$SCRATCH/eval.js" "$ORCH" "$ROADMAP" 2>"$SCRATCH/eval.err")"
EVAL_RC=$?

echo "A: basis change — budget == FIXED_OVERHEAD + EFFECTIVE_TASK_CONTEXT (not fraction × window)"
if [ $EVAL_RC -ne 0 ]; then
  ko "estimator evaluates" "node eval failed rc=$EVAL_RC: $(cat "$SCRATCH/eval.err")"
else
  OBUD=$(echo "$EVAL_OUT" | node -e 'const d=JSON.parse(require("fs").readFileSync(0));console.log(d.orch.budget)')
  RBUD=$(echo "$EVAL_OUT" | node -e 'const d=JSON.parse(require("fs").readFileSync(0));console.log(d.roadmap.budget)')
  OFIX=$(echo "$EVAL_OUT" | node -e 'const d=JSON.parse(require("fs").readFileSync(0));console.log(d.orch.fixed+d.orch.eff)')
  [ "$OBUD" = "$EXPECTED_BUDGET" ] && ok "orchestrated.js budget == $EXPECTED_BUDGET" || ko "orchestrated budget" "got $OBUD, want $EXPECTED_BUDGET"
  [ "$RBUD" = "$EXPECTED_BUDGET" ] && ok "roadmap.js budget == $EXPECTED_BUDGET" || ko "roadmap budget" "got $RBUD, want $EXPECTED_BUDGET"
  [ "$OFIX" = "$EXPECTED_BUDGET" ] && ok "budget == FIXED_OVERHEAD + EFFECTIVE (not $OLD_BUDGET)" || ko "basis identity" "fixed+eff=$OFIX"
  [ "$OBUD" != "$OLD_BUDGET" ] && ok "dead 600K basis is gone" || ko "dead basis" "budget still $OLD_BUDGET"

  echo "B: lockstep — both estimateWaveTokens copies identical for one fixture wave"
  IDENT=$(echo "$EVAL_OUT" | node -e 'const d=JSON.parse(require("fs").readFileSync(0));console.log((d.orch.budget===d.roadmap.budget&&d.orch.predicted===d.roadmap.predicted&&d.orch.over===d.roadmap.over)?"yes":"no")')
  [ "$IDENT" = "yes" ] && ok "predicted/budget/over identical across both copies" || ko "lockstep" "copies diverge: $EVAL_OUT"

  echo "C: over-budget fixture evaluates to completion, over==true (non-blocking precondition)"
  BIGOVER=$(echo "$EVAL_OUT" | node -e 'const d=JSON.parse(require("fs").readFileSync(0));console.log(d.big.over?"yes":"no")')
  [ "$BIGOVER" = "yes" ] && ok "over-budget fixture sets over:true and did not throw" || ko "over-budget eval" "over!=true: $EVAL_OUT"
fi

echo "D: no shared estimator module (ADR-039)"
if grep -Eq "import .* from .*(estimate|budget)|require\(" "$ORCH" "$ROADMAP"; then
  ko "no estimator import" "found an import/require of the estimator"
else
  ok "neither script imports/requires the estimator — triplication preserved"
fi

echo "E: nimble.js has no inline estimateWaveTokens (AC-004)"
if grep -q "function estimateWaveTokens" "$NIMBLE"; then
  ko "nimble no estimator def" "nimble.js defines estimateWaveTokens"
else
  ok "nimble.js carries only the doctrinal comment, no function def"
fi

echo "F: WARN-only channel intact (ADR-086 D4 — AC-006/AC-007)"
grep -q "warn('context-budget'" "$ORCH" && ok "orchestrated budget over-branch calls warn(...)" || ko "orch budget warn" "warn('context-budget' not found"
grep -q "warn('context-budget'" "$ROADMAP" && ok "roadmap budget over-branch calls warn(...)" || ko "roadmap budget warn" "warn('context-budget' not found"
for f in "$ORCH" "$ROADMAP"; do
  n=$(basename "$f")
  if grep -Eq "criterion_match: ?'none'" "$f" && grep -Eq "recommended_disposition: ?'DISMISS'" "$f"; then
    ok "$n warn() hardcodes criterion_match:'none' / DISMISS"
  else
    ko "$n warn channel" "warn() does not hardcode none/DISMISS"
  fi
done
# The budget reason must never reach criterionFindings (surfaceRequired is criterionFindings-driven).
if grep -Eqi "criterionFindings\.push.*budget|criterionFindings\.push.*context-budget" "$ORCH" "$ROADMAP"; then
  ko "budget never criterion" "a budget finding reaches criterionFindings"
else
  ok "budget reason never pushed to criterionFindings — surfaceRequired unaffected"
fi

echo "G: no live '60% of ... window' WARN string (AC-005)"
if grep -q "60% of" "$ORCH" || grep -q "60% of" "$ROADMAP"; then
  ko "no 60% WARN string" "'60% of' still present in a workflow script"
else
  ok "no '60% of' string in either workflow script"
fi

echo "H: spec-decomposer doctrine states the calibrated basis (AC-002 doc arm)"
if grep -q "0.60 × 1_000_000" "$DECOMP"; then
  ko "decomposer basis" "Step 2c still says '0.60 × 1_000_000'"
elif grep -q "FIXED_OVERHEAD + EFFECTIVE_TASK_CONTEXT" "$DECOMP" || grep -q "FIXED_OVERHEAD + ~80K" "$DECOMP"; then
  ok "Step 2c states FIXED_OVERHEAD + effective basis"
else
  ko "decomposer basis" "Step 2c does not state the calibrated basis"
fi

echo
echo "=================================================================="
echo "test-budget-basis: PASS=$PASS FAIL=$FAIL"
if [ $FAIL -gt 0 ]; then echo -e "FAILURES:${FAIL_DETAIL}"; exit 1; fi
echo "ALL GREEN"
