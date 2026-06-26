#!/usr/bin/env bash
# Deterministic-detector + round-trip unit tests for the ADR-104 UI-surface floor (ui-spec-trigger W3/UST-T7).
# Tests the REAL predicate extracted from orchestrated.js (not a copy — so the test fails if the shipping
# code drifts), the lockstep roadmap.js twin, and the **Has UI:** carry round-trip through wave-manifest.py.
# Exit 0 = all PASS; exit 1 = a FAIL.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ORCH="${REPO_ROOT}/core/scripts/workflows/orchestrated.js"
RM="${REPO_ROOT}/core/scripts/workflows/roadmap.js"
WM="${REPO_ROOT}/core/scripts/wave-manifest.py"
for f in "$ORCH" "$RM" "$WM"; do [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }; done

PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }
SCRATCH=$(mktemp -d); trap "rm -rf '$SCRATCH'" EXIT

# ---- A. exercise the REAL orchestrated.js predicate (extracted by brace-matching) ----
# The node harness reads orchestrated.js, extracts normalizePlannedPath/isUiSurfacePath/hasUiSurface by name
# (balanced-brace slice), evals them, and asserts. If extraction fails or behavior drifts, the test fails.
node - "$ORCH" <<'NODE'
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
function extract(name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('predicate not found in orchestrated.js: ' + name);
  let depth = 0, started = false;
  for (let j = src.indexOf('{', start); j < src.length; j++) {
    if (src[j] === '{') { depth++; started = true; }
    else if (src[j] === '}') { depth--; if (started && depth === 0) return src.slice(start, j + 1); }
  }
  throw new Error('unbalanced braces extracting ' + name);
}
eval(extract('normalizePlannedPath') + '\n' + extract('isUiSurfacePath') + '\n' + extract('hasUiSurface'));
const ui = pf => hasUiSurface([{ planned_files: pf }]);
let pass = 0, fail = 0;
const T = (d, exp, got) => { if (exp === got) { console.log('  PASS: ' + d); pass++; } else { console.log('  FAIL: ' + d + ' (exp ' + exp + ', got ' + got + ')'); fail++; } };
// POSITIVE
T('REAL orch predicate: .tsx flags UI', true, ui(['src/components/Foo.tsx']));
T('REAL orch predicate: app/ dir flags UI', true, ui(['app/dashboard/page.ts']));
T('REAL orch predicate: pages/ dir flags UI', true, ui(['pages/index.ts']));
T('REAL orch predicate: .scss flags UI', true, ui(['styles/main.scss']));
T('REAL orch predicate: .vue flags UI', true, ui(['src/Widget.vue']));
T('REAL orch predicate: PascalCase Components/ flags UI (SA-INFO-1)', true, ui(['src/Components/Btn.ts']));
T('REAL orch predicate: terse UI wave (single .jsx) flags UI', true, ui(['x.jsx']));
// NEGATIVE — this epic's own infra wave (the dogfood, AC-017)
T('REAL orch predicate: this-epic infra wave (.js/.py/.md) is NOT UI', false,
  hasUiSurface([{ planned_files: ['core/scripts/workflows/orchestrated.js'] }, { planned_files: ['core/scripts/wave-manifest.py'] }, { planned_files: ['docs/decisions/ADR-104.md'] }]));
T('REAL orch predicate: plain .ts backend is NOT UI', false, ui(['src/server/db.ts']));
// SPOOF / non-spoofability (AC-002)
T('REAL orch predicate: ../escape.tsx does NOT flag (suspicious)', false, ui(['../../etc/escape.tsx']));
T('REAL orch predicate: /abs/Button.tsx does NOT flag (absolute)', false, ui(['/abs/Button.tsx']));
T('REAL orch predicate: substring uicomponents.ts does NOT flag (segment match)', false, ui(['lib/uicomponents.ts']));
T('REAL orch predicate: empty/undefined is false', false, hasUiSurface(undefined));
process.exit(fail > 0 ? 1 : 0);
NODE
if [ $? -eq 0 ]; then ok "orchestrated.js REAL predicate: all detection classes correct"; else ko "orch predicate" "see FAIL lines above"; fi

# ---- B. lockstep guard: roadmap.js twin must share the same extension list + dir segments ----
ext_orch=$(grep -oE 'tsx\|jsx\|vue\|svelte\|css\|scss' "$ORCH" | head -1)
ext_rm=$(grep -oE 'tsx\|jsx\|vue\|svelte\|css\|scss' "$RM" | head -1)
seg_orch=$(grep -c "\['components', 'app', 'pages', 'ui'\]" "$ORCH")
seg_rm=$(grep -c "\['components', 'app', 'pages', 'ui'\]" "$RM")
if [ -n "$ext_orch" ] && [ "$ext_orch" = "$ext_rm" ] && [ "$seg_orch" -ge 1 ] && [ "$seg_rm" -ge 1 ]; then
  ok "lockstep: roadmap.js twin shares the same UI extension list + dir segments as orchestrated.js"
else
  ko "lockstep" "predicate drift between engines (ext_orch='$ext_orch' ext_rm='$ext_rm' seg_orch=$seg_orch seg_rm=$seg_rm)"
fi

# ---- C. round-trip: **Has UI:** header → wave-manifest.py → manifest has_ui (true AND false AND absent) ----
mk_wave() {  # mk_wave <file> <has-ui-line-or-empty>
  { echo "# Wave: wave-rt"; echo "**Protocol version:** 3"; [ -n "$2" ] && echo "$2"; echo;
    echo "## Tickets"; echo;
    echo "### RT-T1: t"; echo "- depends_on: []"; echo "- planned_files: [src/components/X.tsx]";
    echo "- acceptance: [AC-1]"; echo "- gate_recommendations: [code-reviewer]";
    echo "- manual_review_required: true"; echo "- description: |"; echo "    body"; } > "$1"
}
rt() {  # rt <label> <has-ui-line> <expected true|false>
  mk_wave "$SCRATCH/rt.md" "$2"
  python3 "$WM" write-from-plan "$SCRATCH/rt.md" "$SCRATCH/rt.json" >/dev/null 2>&1
  got=$(python3 -c "import json;print(str(json.load(open('$SCRATCH/rt.json')).get('has_ui')).lower())" 2>/dev/null)
  if [ "$got" = "$3" ]; then ok "round-trip: $1"; else ko "round-trip $1" "expected has_ui=$3, got $got"; fi
}
rt "**Has UI:** true → has_ui=true"  "**Has UI:** true"  "true"
rt "**Has UI:** false → has_ui=false" "**Has UI:** false" "false"
rt "absent header → has_ui=false (legacy-safe)" "" "false"

echo ""
echo "============================================"
echo "TOTAL: $((PASS+FAIL)) — PASS: $PASS, FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then echo -e "FAILURES:$FAIL_DETAIL"; exit 1; fi
echo "ALL GREEN"; exit 0
