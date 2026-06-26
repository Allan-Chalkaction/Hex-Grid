#!/usr/bin/env bash
# Synthetic test harness for wave-partition-aware graph validation in roadmap.js
# (planning-ergonomics Wave 2 / PEC-T5 — MUST-PASS exit gate i). Proves validateWavePartition:
#   AC-014a  a valid cross-`wave_slug` edge (depended-on wave before dependent wave, disjoint sinks) → CLEAN.
#   AC-014b  a planted cross-wave CYCLE (acyclic at ticket level, cyclic at wave level) → REJECTED.
#   AC-014c  an UNEDGED shared cross-wave planned_files sink (parallel cross-wave tickets) → REJECTED.
#   plus: an intra-wave sequencing edge sharing a sink (same wave) is NOT flagged by the partition rule.
# Extracts the in-engine validateWavePartition (ADR-039 — no shared module; the engine fn IS the SUT).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROADMAP="$HERE/workflows/roadmap.js"
PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }
SCRATCH=$(mktemp -d); trap "rm -rf '$SCRATCH'" EXIT

if ! command -v node >/dev/null 2>&1; then echo "SKIP: node not installed"; exit 0; fi

cat > "$SCRATCH/gp.test.mjs" <<'NODE'
import { readFileSync } from 'node:fs'
const src = readFileSync(process.env.ROADMAP_JS, 'utf8')
// Extract the in-engine function by name (mirror test-orchestrated-behavioral.mjs): from `\nfunction NAME(`
// to the first lone `}` at column 0 — robust to template-literal `${...}` braces inside the body.
const m = src.match(/\nfunction validateWavePartition\([\s\S]*?\n\}/m)
if (!m) { console.error('EXTRACT_FAIL'); process.exit(2) }
const make = new Function(m[0] + '\nreturn validateWavePartition;')
const validateWavePartition = make()

const out = {}
// (a) valid cross-wave edge: wave-2 depends on wave-1; disjoint sinks → clean.
out.valid = validateWavePartition([
  { key: 'A-T1', wave_slug: 'wave-1-a', depends_on: [], planned_files: ['a.js'] },
  { key: 'B-T1', wave_slug: 'wave-2-b', depends_on: ['A-T1'], planned_files: ['b.js'] },
])
// (b) planted cross-wave CYCLE: wave-a -> wave-b (A-T1->B-T1) and wave-b -> wave-a (B-T1->A-T2). Ticket
//     graph is acyclic (A-T1->B-T1->A-T2), but the WAVE ordering is cyclic.
out.cycle = validateWavePartition([
  { key: 'A-T1', wave_slug: 'wave-a', depends_on: ['B-T1'], planned_files: ['a1.js'] },
  { key: 'B-T1', wave_slug: 'wave-b', depends_on: ['A-T2'], planned_files: ['b1.js'] },
  { key: 'A-T2', wave_slug: 'wave-a', depends_on: [], planned_files: ['a2.js'] },
])
// (c) unedged shared cross-wave sink: two PARALLEL cross-wave tickets share x.js with no edge → reject.
out.sink = validateWavePartition([
  { key: 'A-T1', wave_slug: 'wave-a', depends_on: [], planned_files: ['x.js'] },
  { key: 'B-T1', wave_slug: 'wave-b', depends_on: [], planned_files: ['x.js'] },
])
// (d) intra-wave shared sink with a sequencing edge (same wave) → NOT a partition violation.
out.intra = validateWavePartition([
  { key: 'A-T1', wave_slug: 'wave-a', depends_on: [], planned_files: ['shared.js'] },
  { key: 'A-T2', wave_slug: 'wave-a', depends_on: ['A-T1'], planned_files: ['shared.js'] },
])
console.log(JSON.stringify({ valid: out.valid.length, cycle: out.cycle.length, sink: out.sink.length, intra: out.intra.length, cycleMsg: out.cycle[0]||'', sinkMsg: out.sink[0]||'' }))
NODE

RES=$(ROADMAP_JS="$ROADMAP" node "$SCRATCH/gp.test.mjs" 2>"$SCRATCH/gp.err")
if [ $? -ne 0 ]; then
  ko "extract + run validateWavePartition" "$(cat "$SCRATCH/gp.err" | tail -5)"
else
  g() { echo "$RES" | node -e "const d=JSON.parse(require('fs').readFileSync(0));console.log(d$1)"; }
  echo "AC-014a: valid cross-wave edge validates clean"
  [ "$(g '.valid')" = "0" ] && ok "valid cross-wave edge → no errors" || ko "AC-014a" "errors=$(g '.valid')"
  echo "AC-014b: planted cross-wave cycle rejected"
  [ "$(g '.cycle')" != "0" ] && ok "cross-wave cycle → rejected ($(g '.cycleMsg'))" || ko "AC-014b" "cycle not rejected"
  echo "AC-014c: unedged shared cross-wave sink rejected"
  [ "$(g '.sink')" != "0" ] && ok "unedged shared cross-wave sink → rejected ($(g '.sinkMsg'))" || ko "AC-014c" "shared sink not rejected"
  echo "intra-wave shared sink (sequencing edge) is NOT a partition violation"
  [ "$(g '.intra')" = "0" ] && ok "intra-wave shared sink with edge → no partition error" || ko "intra-wave false-positive" "errors=$(g '.intra')"
fi

# Confirm it's wired into the fail-closed crit-1 surface at the call site.
echo "AC-014: wired into the crit-1 DECOMP-GRAPH fail-closed surface"
if grep -q "validateWavePartition(tickets)" "$ROADMAP" && grep -q "DECOMP-GRAPH" "$ROADMAP"; then
  ok "validateWavePartition called at the graph-validation site → crit-1 DECOMP-GRAPH"
else
  ko "wire-to-consumer" "validateWavePartition not wired into the DECOMP-GRAPH surface"
fi

echo
echo "=================================================================="
echo "test-graph-partition: PASS=$PASS FAIL=$FAIL"
if [ $FAIL -gt 0 ]; then echo -e "FAILURES:${FAIL_DETAIL}"; exit 1; fi
echo "ALL GREEN"
