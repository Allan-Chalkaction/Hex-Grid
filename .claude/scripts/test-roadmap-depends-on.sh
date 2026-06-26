#!/usr/bin/env bash
# Regression guard for the per-wave depends_on schema-parse filter (SHR3-T9 / AC-030).
#
# A per-wave '# Wave:' file is validated STANDALONE by wave-manifest.py, so it must carry IN-WAVE
# depends_on ONLY. The cross-wave-dep fix (renderWaveSchema's inWaveKeys/inWaveDeps — landed in commit
# 09f3d11, "renderWaveSchema cross-wave dep fix"; the SHR3 spec cited 9313174) filters every ticket's
# depends_on to in-wave keys before rendering, so a wave-N dep never leaks into a wave-M file (which would
# read as an unknown-ticket + a phantom cycle at standalone parse).
#
# This test is ADDITIVE + behavior-asserting — it does NOT re-implement the filter (the whole point of
# AC-030 is that the filter logic stays untouched by the substrate-hardening-round-3 epic). It extracts the
# REAL renderWaveSchema (brace-balanced) from roadmap.js + its helper deps, renders a multi-wave fixture,
# and asserts in-wave-deps-only.
#
# Exit 0 = all PASS; exit 1 = a FAIL.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ROADMAP="${REPO_ROOT}/core/scripts/workflows/roadmap.js"
[ -f "$ROADMAP" ] || { echo "ERROR: $ROADMAP not found" >&2; exit 1; }

PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }
SCRATCH=$(mktemp -d); trap "rm -rf '$SCRATCH'" EXIT

cat > "$SCRATCH/render.js" <<'NODE'
const fs = require('fs')
const src = fs.readFileSync(process.argv[2], 'utf8')
// Brace-balanced slice of a named `function NAME(`.
function extractFn(name) {
  const s = src.indexOf('function ' + name + '(')
  if (s < 0) throw new Error('function not found: ' + name)
  let depth = 0, started = false
  for (let j = src.indexOf('{', s); j < src.length; j++) {
    if (src[j] === '{') { depth++; started = true }
    else if (src[j] === '}') { depth--; if (started && depth === 0) return src.slice(s, j + 1) }
  }
  throw new Error('unbalanced braces extracting ' + name)
}
// Slice an inclusive line range from a start anchor to an end anchor (the carve-out block is a
// regex-literal array with a `.map(...)` tail + the _isCarveOut arrow — too gnarly for a bracket
// balancer, so we lift the whole block verbatim between two stable anchors).
function extractRange(startAnchor, endAnchor) {
  const lines = src.split('\n')
  let s = -1, e = -1
  for (let i = 0; i < lines.length; i++) {
    if (s < 0 && lines[i].includes(startAnchor)) s = i
    if (s >= 0 && lines[i].includes(endAnchor)) { e = i; break }
  }
  if (s < 0 || e < 0) throw new Error('range not found: ' + startAnchor + ' .. ' + endAnchor)
  return lines.slice(s, e + 1).join('\n')
}
// Compose the dependency closure renderWaveSchema needs, in declaration order. The carve-out block
// (the REAL _CARVE_OUT_GLOBS regexps + _isCarveOut) is lifted verbatim so the render is the real one.
const code = [
  extractRange('const _CARVE_OUT_GLOBS = [', 'const _isCarveOut = '),
  extractFn('normalizePlannedPath'),
  extractFn('isUiSurfacePath'),
  extractFn('hasUiSurface'),
  extractFn('renderWaveSchema'),
].join('\n')
eval(code)

// --- multi-wave fixture: wave-a + wave-b. wave-b's T-010 declares an IN-wave dep (T-011) AND a
//     CROSS-wave dep (A-T1, which lives in wave-a). The per-wave render of wave-b must keep T-011
//     and DROP A-T1. ---
const waveB = [
  { key: 'B-T010', depends_on: ['B-T011', 'A-T1'], planned_files: ['core/x.js'], acceptance: ['AC-1'], gates: ['code-reviewer'], description: 'b ten' },
  { key: 'B-T011', depends_on: [], planned_files: ['core/y.js'], acceptance: ['AC-2'], gates: ['code-reviewer'], description: 'b eleven' },
]
const rendered = renderWaveSchema('wave-b', waveB)
console.log('---RENDERED-START---')
console.log(rendered)
console.log('---RENDERED-END---')
NODE

OUT="$(node "$SCRATCH/render.js" "$ROADMAP" 2>"$SCRATCH/render.err")"
if [ $? -ne 0 ]; then
  ko "render extraction" "node failed: $(cat "$SCRATCH/render.err")"
else
  # The B-T010 depends_on line in the rendered wave-b file.
  DEP_LINE="$(echo "$OUT" | grep -A1 "### B-T010" | grep "depends_on")"
  echo "  (B-T010 rendered depends_on: ${DEP_LINE})"
  # AC-030 assertion 1: the in-wave dep B-T011 survives.
  if echo "$DEP_LINE" | grep -q "B-T011"; then
    ok "in-wave dep (B-T011) is preserved in the per-wave render"
  else
    ko "in-wave dep preserved" "B-T011 missing from: $DEP_LINE"
  fi
  # AC-030 assertion 2: the CROSS-wave dep A-T1 is filtered OUT (never leaks into wave-b's file).
  if echo "$DEP_LINE" | grep -q "A-T1"; then
    ko "cross-wave dep filtered" "A-T1 leaked into wave-b's depends_on: $DEP_LINE"
  else
    ok "cross-wave dep (A-T1) is filtered out of the per-wave render (in-wave-deps-only)"
  fi
  # The wave file still parses as a '# Wave:' schema (sanity: the standalone-validatable shape).
  if echo "$OUT" | grep -q "^# Wave: wave-b"; then
    ok "rendered per-wave file carries the standalone '# Wave:' header (wave-manifest.py-parseable shape)"
  else
    ko "wave header" "rendered file missing '# Wave: wave-b' header"
  fi
fi

echo ""
echo "============================================"
echo "TOTAL: $((PASS+FAIL)) — PASS: $PASS, FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then echo -e "FAILURES:$FAIL_DETAIL"; exit 1; fi
echo "ALL GREEN"; exit 0
