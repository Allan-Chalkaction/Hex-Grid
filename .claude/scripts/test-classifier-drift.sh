#!/usr/bin/env bash
# Drift-guard + behavior harness for the tier/sensitive/UI classifier family duplicated across the three
# Workflow scripts (SHR3-T2 / ADR-039 contract 2 — duplication is intentional; a runtime cross-file
# require()/import is FORBIDDEN, so drift is caught by THIS test, not prevented by a shared module).
# Mirrors the estimateWaveTokens drift-guard precedent (test-budget-basis.sh): brace-balanced extraction +
# lockstep equality.
#
# The classifier family (canonical source = orchestrated.js):
#   normalizePlannedPath, isCosmeticOnlyPath, isUiSurfacePath, hasUiSurface  (function bodies)
#   SENSITIVE (regex literal) + sensitiveText                                 (orchestrated-only — single source)
#
# Coverage:
#   A. AC-004 — each classifier body present in a script is BYTE-IDENTICAL across all scripts that carry it.
#   B. AC-004 — the guard FIRES: mutating one copy in a fixture makes the byte-equality check go RED.
#   C. AC-005 — table-driven behavior: the canonical classifiers produce the expected verdicts for
#               docs-only / sensitive / UI-surface / spoof cases (ADR-104 floor + ADR-018 crit-3 unchanged).
#   D. AC-006 — no NEW cross-file runtime import between the three scripts (grep clean).
#
# Exit 0 = all PASS; exit 1 = a FAIL.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ORCH="${REPO_ROOT}/core/scripts/workflows/orchestrated.js"
NIMBLE="${REPO_ROOT}/core/scripts/workflows/nimble.js"
ROADMAP="${REPO_ROOT}/core/scripts/workflows/roadmap.js"
for f in "$ORCH" "$NIMBLE" "$ROADMAP"; do [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }; done

PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }
SCRATCH=$(mktemp -d); trap "rm -rf '$SCRATCH'" EXIT

# --- shared Node extractor: brace-balanced function-body slice (same idiom as test-budget-basis.sh) ---
cat > "$SCRATCH/drift.js" <<'NODE'
const fs = require('fs')
function extract(src, name) {
  const s = src.indexOf('function ' + name + '(')
  if (s < 0) return null
  let depth = 0, started = false
  for (let j = src.indexOf('{', s); j < src.length; j++) {
    if (src[j] === '{') { depth++; started = true }
    else if (src[j] === '}') { depth--; if (started && depth === 0) return src.slice(s, j + 1) }
  }
  throw new Error('unbalanced braces extracting ' + name)
}
// Extract the SENSITIVE regex literal line (a const, not a function).
function extractSensitive(src) {
  const m = src.match(/const SENSITIVE = \/[^\n]*\n/)
  return m ? m[0] : null
}
const files = { orchestrated: process.argv[2], nimble: process.argv[3], roadmap: process.argv[4] }
const srcs = {}
for (const k in files) srcs[k] = fs.readFileSync(files[k], 'utf8')
const FNS = ['normalizePlannedPath', 'isCosmeticOnlyPath', 'isUiSurfacePath', 'hasUiSurface']
const out = { drift: [], present: {} }
for (const fn of FNS) {
  const bodies = {}
  for (const k in files) { const b = extract(srcs[k], fn); if (b) bodies[k] = b }
  out.present[fn] = Object.keys(bodies)
  const uniq = new Set(Object.values(bodies))
  if (uniq.size > 1) out.drift.push(fn)
}
// SENSITIVE: collect every script that declares it; all declarations must be identical.
const sens = {}
for (const k in files) { const s = extractSensitive(srcs[k]); if (s) sens[k] = s }
out.present.SENSITIVE = Object.keys(sens)
if (new Set(Object.values(sens)).size > 1) out.drift.push('SENSITIVE')
console.log(JSON.stringify(out))
NODE

echo "A: AC-004 — every classifier body is byte-identical across the scripts that carry it"
RES="$(node "$SCRATCH/drift.js" "$ORCH" "$NIMBLE" "$ROADMAP" 2>"$SCRATCH/drift.err")"
if [ $? -ne 0 ]; then
  ko "drift extraction" "node failed: $(cat "$SCRATCH/drift.err")"
else
  NDRIFT=$(echo "$RES" | node -e 'const d=JSON.parse(require("fs").readFileSync(0));console.log(d.drift.length)')
  if [ "$NDRIFT" = "0" ]; then
    ok "no classifier drift — all copies byte-identical (normalizePlannedPath/isCosmeticOnlyPath/isUiSurfacePath/hasUiSurface/SENSITIVE)"
  else
    DRIFTED=$(echo "$RES" | node -e 'const d=JSON.parse(require("fs").readFileSync(0));console.log(d.drift.join(","))')
    ko "classifier drift" "DRIFT in: $DRIFTED"
  fi
  # Sanity: each classifier is present in at least one script (extraction actually found them).
  PRES_OK=$(echo "$RES" | node -e 'const d=JSON.parse(require("fs").readFileSync(0));console.log(Object.values(d.present).every(a=>a.length>=1)?"yes":"no")')
  [ "$PRES_OK" = "yes" ] && ok "every classifier was located in ≥1 script (extraction is live, not a no-op)" || ko "extraction live" "a classifier was found in 0 scripts"
fi

echo "B: AC-004 — the guard FIRES (a mutated copy goes RED)"
# Copy roadmap.js into the scratch dir, mutate ONE classifier body, and confirm the drift check reports it.
cp "$ROADMAP" "$SCRATCH/roadmap-mut.js"
# Mutate isUiSurfacePath: drop 'scss' from the extension list (a real semantic divergence).
sed -i.bak "s/tsx|jsx|vue|svelte|css|scss/tsx|jsx|vue|svelte|css/" "$SCRATCH/roadmap-mut.js"
if ! diff -q "$ROADMAP" "$SCRATCH/roadmap-mut.js" >/dev/null; then
  RES2="$(node "$SCRATCH/drift.js" "$ORCH" "$NIMBLE" "$SCRATCH/roadmap-mut.js" 2>/dev/null)"
  MUT_DRIFT=$(echo "$RES2" | node -e 'const d=JSON.parse(require("fs").readFileSync(0));console.log(d.drift.includes("isUiSurfacePath")?"yes":"no")')
  [ "$MUT_DRIFT" = "yes" ] && ok "mutating one copy makes the drift guard go RED (a guard that can fail)" || ko "guard fires" "mutation NOT detected: $RES2"
else
  ko "guard fires" "sed mutation did not change the file (extension list not found)"
fi

echo "C: AC-005 — behavior-preserving: table-driven verdicts (ADR-104 floor + ADR-018 crit-3 unchanged)"
cat > "$SCRATCH/behavior.js" <<'NODE'
const fs = require('fs')
function extract(src, name) {
  const s = src.indexOf('function ' + name + '(')
  if (s < 0) return null
  let depth = 0, started = false
  for (let j = src.indexOf('{', s); j < src.length; j++) {
    if (src[j] === '{') { depth++; started = true }
    else if (src[j] === '}') { depth--; if (started && depth === 0) return src.slice(s, j + 1) }
  }
}
const src = fs.readFileSync(process.argv[2], 'utf8')   // orchestrated.js = canonical (carries the whole family)
const sensLit = src.match(/const SENSITIVE = \/[^\n]*\n/)[0]
eval(sensLit
  + 'function sensitiveText(s){return typeof s===\'string\'&&SENSITIVE.test(s)}\n'
  + extract(src, 'normalizePlannedPath') + '\n'
  + extract(src, 'isCosmeticOnlyPath') + '\n'
  + extract(src, 'isUiSurfacePath') + '\n'
  + extract(src, 'hasUiSurface'))
let pass = 0, fail = 0
const T = (d, exp, got) => { if (exp === got) { console.log('    PASS: ' + d); pass++ } else { console.log('    FAIL: ' + d + ' (exp ' + exp + ', got ' + got + ')'); fail++ } }
// cosmetic-only (docs/, tests/, top-level *.md)
T('docs/x.md is cosmetic-only', true, isCosmeticOnlyPath('docs/x.md'))
T('tests/a.test.js is cosmetic-only', true, isCosmeticOnlyPath('tests/a.test.js'))
T('README.md (top-level *.md) is cosmetic-only', true, isCosmeticOnlyPath('README.md'))
T('src/server/db.ts is NOT cosmetic-only', false, isCosmeticOnlyPath('src/server/db.ts'))
T('../escape.md is NOT cosmetic-only (..-escape)', false, isCosmeticOnlyPath('../escape.md'))
T('/abs/x.md is NOT cosmetic-only (absolute)', false, isCosmeticOnlyPath('/abs/x.md'))
// UI surface (ADR-104 floor)
T('src/components/Foo.tsx is UI', true, isUiSurfacePath('src/components/Foo.tsx'))
T('app/page.ts is UI (dir segment)', true, isUiSurfacePath('app/page.ts'))
T('styles/main.scss is UI', true, isUiSurfacePath('styles/main.scss'))
T('src/Components/Btn.ts is UI (PascalCase segment, SA-INFO-1)', true, isUiSurfacePath('src/Components/Btn.ts'))
T('src/server/db.ts is NOT UI', false, isUiSurfacePath('src/server/db.ts'))
T('lib/uicomponents.ts is NOT UI (substring, not segment)', false, isUiSurfacePath('lib/uicomponents.ts'))
T('../x.tsx is NOT UI (..-escape, non-spoofable)', false, isUiSurfacePath('../../etc/x.tsx'))
T('hasUiSurface over a wave with one .tsx', true, hasUiSurface([{ planned_files: ['x.tsx'] }]))
T('hasUiSurface over a backend-only wave', false, hasUiSurface([{ planned_files: ['core/a.py'] }]))
// sensitive-text (ADR-018 crit-3)
T('"auth" text is sensitive', true, sensitiveText('add auth flow'))
T('"migration" text is sensitive', true, sensitiveText('db migration'))
T('".sql" text is sensitive', true, sensitiveText('schema.sql'))
T('"password" text is sensitive', true, sensitiveText('reset password'))
T('"dashboard layout" text is NOT sensitive', false, sensitiveText('dashboard layout'))
process.exit(fail > 0 ? 1 : 0)
NODE
if node "$SCRATCH/behavior.js" "$ORCH"; then
  ok "table-driven behavior verdicts all correct (cosmetic / UI floor / sensitive-text)"
else
  ko "behavior verdicts" "a canonical classifier produced an unexpected verdict (see FAIL lines)"
fi

echo "D: AC-006 — no NEW cross-file runtime import between the three Workflow scripts"
if grep -nE "require\(|^import |from '\.\./" "$NIMBLE" "$ORCH" "$ROADMAP"; then
  ko "no cross-file import" "a require()/import/relative-import appeared in a workflow script"
else
  ok "no require()/import/relative cross-file import in any workflow script (ADR-039 contract 2 intact)"
fi

echo ""
echo "============================================"
echo "TOTAL: $((PASS+FAIL)) — PASS: $PASS, FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then echo -e "FAILURES:$FAIL_DETAIL"; exit 1; fi
echo "ALL GREEN"; exit 0
