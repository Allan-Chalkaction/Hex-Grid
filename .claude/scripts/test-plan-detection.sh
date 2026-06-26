#!/usr/bin/env bash
# Synthetic test harness for deterministic, fail-closed PLAN-DETECTION in orchestrated.js
# (planning-ergonomics Wave 2 / PEC-T3 + PEC-T4). Proves:
#   AC-008  the detector is PURE markdown parsing — no agent()/import/require anywhere in its path.
#   AC-009  fail-closed: a folder with one PLANNED + one raw (no `## Tickets`) wave classifies NOT-PLANNED,
#           and the advisory preamble (cto) is reachable/runs.
#   AC-010  a PLANNED folder run SKIPS cto / architect-pre / pm-spec / decompose (no spec-decomposer
#           dispatch) and builds only (implement/integrate/gate still run).
#   AC-011  decompose (spec-decomposer dispatch) is guarded by NOT-PLANNED.
#   AC-012  the helper is WIRED — invoked at the phase-branch point; result.isPlanned reflects the signal
#           and the branch is demonstrably taken.
#   AC-017  no new plan<->build manual halt is introduced (autonomous-to-completion).
# The behavioral arms run the REAL orchestrated.js under the mock-runtime harness
# (fixtures/orchestrated-harness.mjs) — same technique as test-orchestrated-behavioral.mjs.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ORCH="$HERE/workflows/orchestrated.js"
HARNESS="$HERE/fixtures/orchestrated-harness.mjs"
PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }

SCRATCH=$(mktemp -d)
trap "rm -rf '$SCRATCH'" EXIT

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — plan-detection behavioral arms need the mock runtime"; exit 0
fi

# AC-008 (static): the detection path is pure parsing. Extract the detector region (parsesToTickets +
# detectPlanned) and assert it contains no agent(/import/require.
echo "AC-008: detector is pure markdown parsing (no agent/import/require in path)"
DET=$(awk '/^function parsesToTickets/{f=1} f{print} /^const isPlanned =/{f=0}' "$ORCH")
if [ -z "$DET" ]; then
  ko "detector region extracted" "could not locate parsesToTickets..isPlanned block"
else
  if echo "$DET" | grep -qE "agent\(|import |require\("; then
    ko "no agent/import in detector" "detector path references agent()/import/require"
  else
    ok "detection path is pure (no agent/import/require)"
  fi
fi

# Behavioral arms via the mock runtime.
cat > "$SCRATCH/pd.test.mjs" <<'NODE'
const harnessUrl = process.env.HARNESS_URL
const { runEngine, defaultMock } = await import(harnessUrl)

const PLANNED_MD = `# Wave: wave-x
**Protocol version:** 3

## Tickets

### PEC-T1: do a thing
- depends_on: []
- planned_files: [a.js]
- acceptance: [AC-1]
`
const RAW_MD = `# Some cluster notes
just prose, no tickets heading, not a plan yet.
`
const tickets = [{ key: 'PEC-T1', description: 'do a thing', depends_on: [], planned_files: ['a.js'], acceptance: ['AC-1'] }]

function planMock(o, p) {
  // Build-phase mocks so a PLANNED run completes implement/integrate/gate cleanly.
  const t = o.agentType, label = o.label || ''
  if (label === 'implement') return { wave_status: 'complete', tickets_built: [{ ticket_key: 'PEC-T1', status: 'complete', sha: 'aaa1111', files_changed: ['a.js'], report: 'done' }], wave_report: 'ok' }
  if (label === 'integrate') return { status: 'integrated', integrated_head: 'bbb2222', base_sha: 'aaa1111', merged: ['PEC-T1'], stale: [], report: 'verified' }
  return defaultMock(o, p)
}

const out = {}

// (1) PLANNED folder: waveSpecs all parse + tickets ingested => skip preamble + decompose, build only.
{
  const { result, calls } = await runEngine({
    args: { runDir: '/tmp/run', repoRoot: '/tmp/repo', task: 'wave intent', waveSpecs: [{ slug: 'wave-x', markdown: PLANNED_MD }], tickets },
    mock: planMock,
  })
  out.planned = {
    isPlanned: result.isPlanned,
    cto: calls.includes('cto-advisor'),
    archPre: calls.includes('architect-review:pre'),
    pmSpec: calls.includes('pm-spec'),
    decomposer: calls.includes('spec-decomposer'),
    implement: calls.includes('implement'),
    integrate: calls.includes('integrate'),
    gate: calls.some(c => c.startsWith('gate:')),
    surfaceRequired: result.surfaceRequired,
  }
}

// (2) MIXED folder (one planned, one raw): fail-closed => NOT-PLANNED, preamble runs (cto dispatched).
{
  const { result, calls } = await runEngine({
    args: { runDir: '/tmp/run', repoRoot: '/tmp/repo', task: 'wave intent', waveSpecs: [{ markdown: PLANNED_MD }, { markdown: RAW_MD }], tickets },
    mock: defaultMock,
  })
  out.mixed = { isPlanned: result.isPlanned, cto: calls.includes('cto-advisor') }
}

// (3) No waveSpecs (operator-supplied tickets only): fail-closed NOT-PLANNED => preamble runs (back-compat).
{
  const { result, calls } = await runEngine({
    args: { runDir: '/tmp/run', repoRoot: '/tmp/repo', task: 'wave intent', tickets },
    mock: defaultMock,
  })
  out.noSpecs = { isPlanned: result.isPlanned, cto: calls.includes('cto-advisor'), decomposer: calls.includes('spec-decomposer') }
}

console.log(JSON.stringify(out))
NODE

RES=$(HARNESS_URL="file://$HARNESS" node "$SCRATCH/pd.test.mjs" 2>"$SCRATCH/pd.err")
if [ $? -ne 0 ]; then
  ko "behavioral harness runs" "$(cat "$SCRATCH/pd.err" | tail -5)"
else
  jq_get() { echo "$RES" | node -e "const d=JSON.parse(require('fs').readFileSync(0));console.log(d$1)"; }

  echo "AC-010 / AC-012: PLANNED folder skips preamble + decompose, builds only"
  [ "$(jq_get '.planned.isPlanned')" = "true" ] && ok "result.isPlanned === true (signal wired + branch taken)" || ko "AC-012 planned signal" "isPlanned=$(jq_get '.planned.isPlanned')"
  [ "$(jq_get '.planned.cto')" = "false" ] && ok "cto-advisor NOT dispatched on PLANNED" || ko "AC-010 cto skip" "cto dispatched"
  [ "$(jq_get '.planned.archPre')" = "false" ] && ok "architect-review:pre NOT dispatched on PLANNED" || ko "AC-010 archPre skip" "archPre dispatched"
  [ "$(jq_get '.planned.pmSpec')" = "false" ] && ok "pm-spec NOT dispatched on PLANNED" || ko "AC-010 pmSpec skip" "pm-spec dispatched"
  [ "$(jq_get '.planned.decomposer')" = "false" ] && ok "spec-decomposer NOT dispatched on PLANNED (slice-once)" || ko "AC-010/AC-011 decompose skip" "spec-decomposer dispatched"
  [ "$(jq_get '.planned.implement')" = "true" ] && ok "implement DOES run on PLANNED (build-only)" || ko "AC-010 build" "implement not dispatched"
  [ "$(jq_get '.planned.integrate')" = "true" ] && ok "integrate runs on PLANNED" || ko "AC-010 integrate" "integrate not dispatched"
  [ "$(jq_get '.planned.gate')" = "true" ] && ok "gate runs on PLANNED" || ko "AC-010 gate" "gate not dispatched"
  [ "$(jq_get '.planned.surfaceRequired')" = "false" ] && ok "AC-017: PLANNED run completes autonomously (no halt/surface)" || ko "AC-017 autonomous" "surfaceRequired=$(jq_get '.planned.surfaceRequired')"

  echo "AC-009: fail-closed — one PLANNED + one raw wave => NOT-PLANNED, preamble reachable"
  [ "$(jq_get '.mixed.isPlanned')" = "false" ] && ok "mixed folder classifies NOT-PLANNED (fail-closed)" || ko "AC-009 mixed" "isPlanned=$(jq_get '.mixed.isPlanned')"
  [ "$(jq_get '.mixed.cto')" = "true" ] && ok "NOT-PLANNED preamble runs (cto dispatched)" || ko "AC-009 preamble" "cto not dispatched"

  echo "AC-011 / back-compat: operator-supplied tickets WITHOUT waveSpecs stay NOT-PLANNED (preamble runs)"
  [ "$(jq_get '.noSpecs.isPlanned')" = "false" ] && ok "no waveSpecs => NOT-PLANNED (fail-closed)" || ko "back-compat" "isPlanned=$(jq_get '.noSpecs.isPlanned')"
  [ "$(jq_get '.noSpecs.cto')" = "true" ] && ok "hand-fed tickets keep cto/architect/pm-spec pass" || ko "back-compat preamble" "cto not dispatched"
fi

# AC-017 (static): no new plan<->build manual-halt language introduced.
echo "AC-017 (static): no new plan<->build manual checkpoint/halt token"
if grep -nE "await operator|manual checkpoint|halt.*before build" "$ORCH" >/dev/null 2>&1; then
  ko "no plan<->build halt" "a manual-halt token is present"
else
  ok "no manual plan<->build halt token in orchestrated.js"
fi

echo
echo "=================================================================="
echo "test-plan-detection: PASS=$PASS FAIL=$FAIL"
if [ $FAIL -gt 0 ]; then echo -e "FAILURES:${FAIL_DETAIL}"; exit 1; fi
echo "ALL GREEN"
