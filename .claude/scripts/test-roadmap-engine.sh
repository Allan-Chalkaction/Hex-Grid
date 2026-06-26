#!/usr/bin/env bash
# test-roadmap-engine.sh — ADR-055: roadmap runs as a Workflow script + persist_roadmap
# writes the canonical artifact. Functional (not just grep): parses roadmap.js the way the
# Workflow tool wraps it, then drives persist_roadmap end-to-end for E (autonomous + attended)
# and W (with the wave-manifest schema check). Read-only against the repo (temp cwd for canonical).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PERSIST="$REPO_ROOT/core/scripts/persist-run-artifacts.py"
RJS="$REPO_ROOT/core/scripts/workflows/roadmap.js"
PASS=0; FAIL=0
ok(){ echo "PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# --- T1: roadmap.js body parses (wrapped in an async fn, as the engine runs it) -----------
# roadmap.js is self-contained per ADR-065 (amended 2026-06-13): runIntentCapture is INLINE, no
# top-level import (the Workflow runtime forbids imports), so the wrapped-body parse check needs no strip.
node -e '
const fs=require("fs");
let s=fs.readFileSync(process.argv[1],"utf8").replace(/^export const meta/m,"const meta");
fs.writeFileSync("/tmp/_rmengine.mjs","async function __wf(){\n"+s+"\n}\n");
' "$RJS"
if node --check /tmp/_rmengine.mjs 2>/dev/null; then ok "roadmap.js body parses clean (ESM, wrapped)"; else bad "roadmap.js has a syntax error"; fi

# --- T2: persist_roadmap Phase E autonomous -> canonical roadmap.md ------------------------
T=$(mktemp -d); ( cd "$T" && mkdir -p run/findings
  cat > ret.json <<'EOF'
{"track":"roadmap","phase":"E","epicSlug":"eng-test","roadmapMarkdown":"# Roadmap — eng-test\n\nWave 1.\n","findings":{"research":"x","cto-advisor":"SIMPLIFY","round-1-recommended-reply":"LOCK"},"criterionFindings":[],"surfaceRequired":false}
EOF
  python3 "$PERSIST" --run-dir "$T/run" --slug eng-test --return-file "$T/ret.json" >/dev/null 2>&1
)
if [ -f "$T/docs/step-3-specs/eng-test/roadmap.md" ]; then ok "Phase E autonomous: canonical docs/step-3-specs/eng-test/roadmap.md written"; else bad "Phase E autonomous: canonical roadmap.md NOT written"; fi
if [ -f "$T/run/findings/cto-advisor.md" ] && [ -f "$T/run/findings/research.md" ]; then ok "Phase E: findings persisted"; else bad "Phase E: findings missing"; fi
if [ -f "$T/run/manifest.json" ] && grep -q '"track": "roadmap"' "$T/run/manifest.json" 2>/dev/null; then ok "Phase E: thin manifest track=roadmap"; else bad "Phase E: manifest missing/wrong track"; fi
rm -rf "$T"

# --- T3: persist_roadmap Phase E ATTENDED -> NO canonical (surfaced for operator lock) -----
T=$(mktemp -d); ( cd "$T" && mkdir -p run/findings
  cat > ret.json <<'EOF'
{"track":"roadmap","phase":"E","epicSlug":"eng-att","attended":true,"roadmapMarkdown":"# draft\n","findings":{"research":"x"},"criterionFindings":[],"surfaceRequired":true,"surfaceType":"roadmap-round"}
EOF
  python3 "$PERSIST" --run-dir "$T/run" --slug eng-att --return-file "$T/ret.json" >/dev/null 2>&1
)
if [ ! -f "$T/docs/step-3-specs/eng-att/roadmap.md" ]; then ok "Phase E attended: canonical NOT written (operator locks)"; else bad "Phase E attended: canonical wrongly written"; fi
if [ -f "$T/run/round-1-draft.md" ]; then ok "Phase E attended: draft written to run folder"; else bad "Phase E attended: draft missing"; fi
rm -rf "$T"

# --- T4: persist_roadmap Phase W -> wave files + schema-parse check passes -----------------
T=$(mktemp -d); ( cd "$T" && mkdir -p run/findings
  # a minimal VALID '# Wave:' schema (single-hyphen key, non-empty planned_files)
  python3 - "$T" "$PERSIST" <<'PY'
import json,sys,os
T,PERSIST=sys.argv[1],sys.argv[2]
# A VALID '# Wave:' schema per docs/step-3-specs/_wave-template.md: '- description: |' block scalar;
# src/ file -> manual_review_required: true (ADR-013 carve-out rule).
wave_md=("# Wave: eng-wave\n\n**Theme:** test.\n**Goal:** test wave parses.\n\n## Tickets\n\n"
         "### EW-T1: do the thing\n"
         "- depends_on: []\n"
         "- planned_files: [src/a.ts]\n"
         "- gate_recommendations: [code-reviewer]\n"
         "- manual_review_required: true\n"
         "- description: |\n"
         "    Implement the thing end to end. Enough detail for pm-spec to expand.\n")
ret={"track":"roadmap","phase":"W","epicSlug":"eng-test","waveSlug":"eng-wave",
     "waveSpecMarkdown":wave_md,"wavePromptsMarkdown":"# prompts\n",
     "findings":{"cto-advisor":"ok","architect-review":"ok","pm-spec":"ok"},
     "criterionFindings":[],"surfaceRequired":False}
open(os.path.join(T,"ret.json"),"w").write(json.dumps(ret))
PY
  python3 "$PERSIST" --run-dir "$T/run" --slug eng-test --return-file "$T/ret.json" > "$T/out.json" 2>/dev/null
)
if [ -f "$T/docs/step-3-specs/eng-test/waves/eng-wave/eng-wave.md" ]; then ok "Phase W: canonical wave .md written to the wave folder"; else bad "Phase W: wave .md NOT written"; fi
if [ -f "$T/docs/step-3-specs/eng-test/waves/eng-wave/eng-wave-prompts.md" ]; then ok "Phase W: -prompts.md written"; else bad "Phase W: -prompts.md missing"; fi
if grep -q '"wave_schema_ok": true' "$T/out.json" 2>/dev/null; then ok "Phase W: wave-manifest schema-parse check PASSED"; else bad "Phase W: schema check did not pass (out: $(cat "$T/out.json" 2>/dev/null | tr -d '\n' | head -c 200))"; fi
rm -rf "$T"

# --- T5: ADR-103 W2 IN-bookend wiring is present (activation guard) -------------------------
# The deterministic checker is inert unless the author emits the section AND the lock runs the gate.
# Assert both halves so the activation text can't silently regress (the BUILT_NOT_ACTIVATED anti-pattern).
if grep -q "Source disposition" "$RJS" && grep -q "ADR-103 W2" "$RJS"; then ok "W2: author prompt requires the '## Source disposition' section"; else bad "W2: author prompt lost the Source-disposition requirement (gate would be inert)"; fi
SKILL_MD="$REPO_ROOT/core/skills/roadmap/SKILL.md"
if grep -q "roadmap-source-coverage.py" "$SKILL_MD"; then ok "W2: lock flow runs the deterministic source-coverage gate"; else bad "W2: lock flow no longer runs roadmap-source-coverage.py (gate unwired)"; fi

echo ""
echo "----------------------------------------"
echo "roadmap-engine tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "All roadmap-engine tests PASSED — ADR-055 roadmap-on-the-engine wired."; exit 0; } || exit 1
