#!/usr/bin/env bash
# Synthetic test harness for the BACK-END CROSS-WAVE DRIFT GATE in orchestrated.js
# (planning-ergonomics Wave 2 / PEC-T6 — MUST-PASS exit gate ii). Proves the gate:
#   AC-015a  FIRES (non-empty finding) on a planted cross-wave break — two parallel cross-wave tickets
#            whose REALIZED files_changed collide (a sink that drifted in post-slice).
#   AC-015b  stays SILENT on a clean run (realized files disjoint).
#   AC-015c  does NOT flag a within-wave shared file (one sequential writer — ADR-062 §3).
#   AC-015d  is WIRED into the post-build (integrate/gate) control flow — proven by running the REAL
#            engine under the mock runtime: a colliding-realized build → result.driftFindings fires and
#            the wave surfaces (criterionFindings/surfaceRequired); a clean build → no drift, no surface.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$HERE/workflows/orchestrated.js"
HARNESS="$HERE/fixtures/orchestrated-harness.mjs"
PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }
SCRATCH=$(mktemp -d); trap "rm -rf '$SCRATCH'" EXIT
if ! command -v node >/dev/null 2>&1; then echo "SKIP: node not installed"; exit 0; fi

cat > "$SCRATCH/dg.test.mjs" <<'NODE'
import { readFileSync } from 'node:fs'
const src = readFileSync(process.env.ORCH_JS, 'utf8')
const m = src.match(/\nfunction detectShippedSinkDrift\([\s\S]*?\n\}/m)
if (!m) { console.error('EXTRACT_FAIL'); process.exit(2) }
const detectShippedSinkDrift = new Function(m[0] + '\nreturn detectShippedSinkDrift;')()

// (a) planted break: parallel cross-wave tickets, planned disjoint, realized collide.
const tickets = [
  { key: 'A-T1', wave_slug: 'wave-a', depends_on: [], planned_files: ['a.js'] },
  { key: 'B-T1', wave_slug: 'wave-b', depends_on: [], planned_files: ['b.js'] },
]
const collide = [
  { ticket_key: 'A-T1', files_changed: ['a.js', 'shared.js'] },
  { ticket_key: 'B-T1', files_changed: ['b.js', 'shared.js'] },
]
const clean = [
  { ticket_key: 'A-T1', files_changed: ['a.js'] },
  { ticket_key: 'B-T1', files_changed: ['b.js'] },
]
// (c) within-wave collision (same wave, one sequential writer) → must NOT flag.
const intra = [
  { key: 'A-T1', wave_slug: 'wave-a', depends_on: [], planned_files: ['x.js'] },
  { key: 'A-T2', wave_slug: 'wave-a', depends_on: [], planned_files: ['y.js'] },
]
const intraReal = [
  { ticket_key: 'A-T1', files_changed: ['shared.js'] },
  { ticket_key: 'A-T2', files_changed: ['shared.js'] },
]
console.log(JSON.stringify({
  fired: detectShippedSinkDrift(tickets, collide).length,
  silent: detectShippedSinkDrift(tickets, clean).length,
  intra: detectShippedSinkDrift(intra, intraReal).length,
  msg: (detectShippedSinkDrift(tickets, collide)[0] || {}).id || '',
}))
NODE

RES=$(ORCH_JS="$ORCH" node "$SCRATCH/dg.test.mjs" 2>"$SCRATCH/dg.err")
if [ $? -ne 0 ]; then
  ko "extract + run detectShippedSinkDrift" "$(cat "$SCRATCH/dg.err" | tail -5)"
else
  g() { echo "$RES" | node -e "const d=JSON.parse(require('fs').readFileSync(0));console.log(d$1)"; }
  echo "AC-015a: drift gate FIRES on planted cross-wave break"
  [ "$(g '.fired')" != "0" ] && ok "planted cross-wave realized collision → finding ($(g '.msg'))" || ko "AC-015a" "did not fire"
  echo "AC-015b: drift gate SILENT on clean run"
  [ "$(g '.silent')" = "0" ] && ok "disjoint realized files → no finding" || ko "AC-015b" "fired on clean ($(g '.silent'))"
  echo "AC-015c: within-wave shared file NOT flagged (one sequential writer)"
  [ "$(g '.intra')" = "0" ] && ok "within-wave realized collision → no finding" || ko "AC-015c" "flagged within-wave ($(g '.intra'))"
fi

# AC-015d — wired into the real post-build control flow (behavioral, via the mock runtime).
cat > "$SCRATCH/dg.behav.mjs" <<'NODE'
const { runEngine, defaultMock } = await import(process.env.HARNESS_URL)
const PLANNED_MD = `# Wave: w\n**Protocol version:** 3\n\n## Tickets\n\n### A-T1: a\n- depends_on: []\n`
const tickets = [
  { key: 'A-T1', wave_slug: 'wave-a', depends_on: [], planned_files: ['a.js'], acceptance: [] },
  { key: 'B-T1', wave_slug: 'wave-b', depends_on: [], planned_files: ['b.js'], acceptance: [] },
]
function mk(filesA, filesB) {
  return (o, p) => {
    if (o.label === 'implement') return {
      wave_status: 'complete',
      tickets_built: [
        { ticket_key: 'A-T1', status: 'complete', sha: 'aaa1111', files_changed: filesA, report: 'done' },
        { ticket_key: 'B-T1', status: 'complete', sha: 'bbb2222', files_changed: filesB, report: 'done' },
      ],
      wave_report: 'ok',
    }
    if (o.label === 'integrate') return { status: 'integrated', integrated_head: 'ccc3333', base_sha: 'aaa1111', merged: ['A-T1', 'B-T1'], stale: [], report: 'verified' }
    return defaultMock(o, p)
  }
}
const base = { runDir: '/tmp/run', repoRoot: '/tmp/repo', task: 'wave', waveSpecs: [{ markdown: PLANNED_MD }], tickets }
const broke = await runEngine({ args: base, mock: mk(['a.js', 'shared.js'], ['b.js', 'shared.js']) })
const okrun = await runEngine({ args: base, mock: mk(['a.js'], ['b.js']) })
console.log(JSON.stringify({
  brokeDrift: (broke.result.driftFindings || []).length,
  brokeSurface: broke.result.surfaceRequired,
  brokeCrit: (broke.result.criterionFindings || []).some(f => f.gate === 'drift'),
  cleanDrift: (okrun.result.driftFindings || []).length,
  cleanSurface: okrun.result.surfaceRequired,
}))
NODE

BRES=$(HARNESS_URL="file://$HARNESS" ORCH_JS="$ORCH" node "$SCRATCH/dg.behav.mjs" 2>"$SCRATCH/dgb.err")
if [ $? -ne 0 ]; then
  ko "behavioral wire-to-consumer" "$(cat "$SCRATCH/dgb.err" | tail -6)"
else
  b() { echo "$BRES" | node -e "const d=JSON.parse(require('fs').readFileSync(0));console.log(d$1)"; }
  echo "AC-015d: wired — real engine invokes the gate post-build"
  [ "$(b '.brokeDrift')" != "0" ] && ok "real run: planted break → driftFindings fired" || ko "AC-015d fire" "no driftFindings in real run"
  [ "$(b '.brokeCrit')" = "true" ] && ok "drift rides criterionFindings (crit-1)" || ko "AC-015d crit" "drift not in criterionFindings"
  [ "$(b '.brokeSurface')" = "true" ] && ok "planted break → wave surfaces (surfaceRequired)" || ko "AC-015d surface" "no surface on drift"
  [ "$(b '.cleanDrift')" = "0" ] && ok "real run: clean build → no drift" || ko "AC-015d clean" "drift on clean run"
  [ "$(b '.cleanSurface')" = "false" ] && ok "clean build → no surface (drift gate silent)" || ko "AC-015d clean surface" "surface on clean run"
fi

echo
echo "=================================================================="
echo "test-drift-gate: PASS=$PASS FAIL=$FAIL"
if [ $FAIL -gt 0 ]; then echo -e "FAILURES:${FAIL_DETAIL}"; exit 1; fi
echo "ALL GREEN"
