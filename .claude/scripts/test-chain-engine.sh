#!/usr/bin/env bash
# Synthetic test harness for the v2 CUSTOM-CHAIN engine (T5c).
# Coverage (no live agents — feeds known workflow-return JSON + temp run dirs):
#   A. chain artifact-sync (persist-run-artifacts.py persist_chain) — happy path:
#      one findings file per step, run-log, thin manifest (track=chain), all steps complete.
#   B. chain artifact-sync — surfaced path: a gate criterion finding -> run surfaced,
#      the offending step blocked, surface_required true.
#   C. routing: track="chain" routes to persist_chain (not nimble/orchestrated); the
#      nimble + orchestrated persist shapes are unaffected by the new branch.
#   D. malformed return rejected (non-object).
#   E. /resume single-chain `next` walks a chain manifest (first non-complete step / BLOCKED / COMPLETE).
#   F. chain.js parses (node --check).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PY=python3
RM="$HERE/run-manifest.py"
PERSIST="$HERE/persist-run-artifacts.py"
PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }

SCRATCH=$(mktemp -d)
trap "rm -rf '$SCRATCH'" EXIT

# ===========================================================================
echo "A: chain artifact-sync (persist_chain) — happy path"
RUN="$SCRATCH/run"; mkdir -p "$RUN/findings"
cat > "$SCRATCH/ret-ok.json" <<'JSON'
{
  "track":"chain",
  "agents":[
    {"agent":"cto-advisor","role":"think","label":"01-cto-advisor"},
    {"agent":"implementer","role":"implement","label":"02-implementer"},
    {"agent":"code-reviewer","role":"gate","label":"03-code-reviewer"}
  ],
  "steps":[
    {"label":"01-cto-advisor","agent":"cto-advisor","role":"think","text":"GO. Approach sound."},
    {"label":"02-implementer","agent":"implementer","role":"implement","text":"COMPLETION_REPORT: created core/x.sh; tests pass."},
    {"label":"03-code-reviewer","agent":"code-reviewer","role":"gate","verdict":"APPROVE","summary":"clean",
     "findings":[{"id":"CR-001","severity":"nit","criterion_match":"none","recommended_disposition":"DISMISS","detail":"a nit"}]}
  ],
  "allFindings":[{"id":"CR-001","criterion_match":"none"}],
  "criterionFindings":[],
  "surfaceRequired":false
}
JSON
$PY "$PERSIST" --run-dir "$RUN" --return-file "$SCRATCH/ret-ok.json" --slug "chain1" --task "build x.sh" >/dev/null 2>&1
[ -f "$RUN/findings/01-cto-advisor.md" ] && [ -f "$RUN/findings/02-implementer.md" ] && [ -f "$RUN/findings/03-code-reviewer.md" ] \
  && ok "one findings file per chain step (in order)" || ko "per-step findings" "missing"
grep -q "COMPLETION_REPORT" "$RUN/findings/02-implementer.md" && ok "implement step report captured" || ko "impl report" "missing body"
grep -q "APPROVE" "$RUN/findings/03-code-reviewer.md" && ok "gate step verdict captured" || ko "gate verdict" "missing"
[ -f "$RUN/run-log.md" ] && grep -q "custom chain" "$RUN/run-log.md" && ok "run-log.md written (chain)" || ko "run-log" "missing"
$PY -c "import json;m=json.load(open('$RUN/manifest.json'));assert m['track']=='chain',m['track'];assert m['status']=='complete',m['status'];assert [s['phase'] for s in m['steps']]==['01-cto-advisor','02-implementer','03-code-reviewer'];assert all(s['status']=='complete' for s in m['steps'])" 2>/dev/null \
  && ok "manifest: track=chain, complete, steps=agent labels all complete" || ko "manifest happy" "wrong state"

# ===========================================================================
echo "B: chain artifact-sync — surfaced path (gate criterion finding -> step blocked)"
RUN2="$SCRATCH/run2"; mkdir -p "$RUN2/findings"
cat > "$SCRATCH/ret-surf.json" <<'JSON'
{
  "track":"chain",
  "agents":[
    {"agent":"backend-implementer","role":"implement","label":"01-backend-implementer"},
    {"agent":"security-auditor","role":"gate","label":"02-security-auditor"}
  ],
  "steps":[
    {"label":"01-backend-implementer","agent":"backend-implementer","role":"implement","text":"COMPLETION_REPORT: added auth route."},
    {"label":"02-security-auditor","agent":"security-auditor","role":"gate","verdict":"REQUEST_CHANGES","summary":"secret in code",
     "findings":[{"id":"SA-1","severity":"critical","criterion_match":"crit-3","recommended_disposition":"ESCALATE","detail":"hardcoded token"}]}
  ],
  "allFindings":[{"id":"SA-1","criterion_match":"crit-3"}],
  "criterionFindings":[{"id":"SA-1","criterion_match":"crit-3","step":"02-security-auditor","detail":"hardcoded token"}],
  "surfaceRequired":true
}
JSON
$PY "$PERSIST" --run-dir "$RUN2" --return-file "$SCRATCH/ret-surf.json" --slug s2 --task t >/dev/null 2>&1
$PY -c "import json;m=json.load(open('$RUN2/manifest.json'));assert m['status']=='surfaced',m['status'];assert m['surface_required'] is True;g=[s for s in m['steps'] if s['phase']=='02-security-auditor'][0];assert g['status']=='blocked',g;i=[s for s in m['steps'] if s['phase']=='01-backend-implementer'][0];assert i['status']=='complete',i" 2>/dev/null \
  && ok "surfaced: run=surfaced, offending gate step blocked, prior step complete" || ko "surfaced path" "wrong state"
grep -q "surface required: \*\*True\*\*" "$RUN2/run-log.md" && ok "run-log reflects surface" || ko "run-log surface" "missing"

# ===========================================================================
echo "C: routing — track=chain routes to persist_chain; nimble + orchestrated unaffected"
# nimble shape (no track) still produces nimble run-log
RUN3="$SCRATCH/run3"; mkdir -p "$RUN3/findings"
cat > "$SCRATCH/ret-nim.json" <<'JSON'
{ "exploreMap":["x"], "implementation":"COMPLETION_REPORT: ok.",
  "review":{"verdict":"APPROVE","summary":"ok","findings":[]},
  "conformance":{"verdict":"CONFORMS","summary":"ok","findings":[]},
  "allFindings":[], "criterionFindings":[], "surfaceRequired":false }
JSON
$PY "$PERSIST" --run-dir "$RUN3" --return-file "$SCRATCH/ret-nim.json" --slug n --task t >/dev/null 2>&1
grep -q "Track:\*\* nimble" "$RUN3/run-log.md" && ok "track-less nimble shape still routes to nimble persist" || ko "nimble routing" "wrong path"
# chain return does NOT get misrouted to nimble (would lack a 'steps' run-log header)
grep -q "custom chain" "$RUN/run-log.md" && ok "chain return routed to persist_chain (not nimble)" || ko "chain routing" "misrouted"
# orchestrated shape (track=orchestrated) still routes to orchestrated persist
RUN3b="$SCRATCH/run3b"; mkdir -p "$RUN3b/findings"
cat > "$SCRATCH/ret-orch.json" <<'JSON'
{ "track":"orchestrated","cto":{"recommendation":"GO","rationale":"ok"},
  "archPre":{"verdict":"SOUND","adr_markdown":"# ADR"},"spec":{"spec_markdown":"# S"},
  "tickets":[{"key":"T-001","description":"a","depends_on":[],"planned_files":[]}],
  "exploreMap":["x"],
  "implementResults":[{"ticket_key":"T-001","status":"complete","sha":"aaa","report":"d"}],
  "integrate":{"status":"integrated","integrated_head":"h","merged":["T-001"],"stale":[],"report":"m"},
  "review":{"verdict":"APPROVE","findings":[]},"conformance":{"verdict":"CONFORMS","findings":[]},
  "contextualReviews":[],"archFinal":{"verdict":"APPROVE","findings":[]},
  "allFindings":[],"criterionFindings":[],"surfaceRequired":false }
JSON
$PY "$PERSIST" --run-dir "$RUN3b" --return-file "$SCRATCH/ret-orch.json" --slug o --task t >/dev/null 2>&1
grep -q "Track:\*\* orchestrated" "$RUN3b/run-log.md" && ok "orchestrated shape still routes to orchestrated persist" || ko "orchestrated routing" "wrong path"

# ===========================================================================
echo "C2: track-less chain return routes via the steps+agents heuristic (CR-002)"
RUN3c="$SCRATCH/run3c"; mkdir -p "$RUN3c/findings"
# same shape as ret-ok.json but with the explicit "track" field REMOVED — must still route to persist_chain
$PY -c "import json;d=json.load(open('$SCRATCH/ret-ok.json'));d.pop('track',None);json.dump(d,open('$SCRATCH/ret-notrack.json','w'))"
$PY "$PERSIST" --run-dir "$RUN3c" --return-file "$SCRATCH/ret-notrack.json" --slug ntr --task t >/dev/null 2>&1
grep -q "custom chain" "$RUN3c/run-log.md" 2>/dev/null && $PY -c "import json;m=json.load(open('$RUN3c/manifest.json'));assert m['track']=='chain',m['track']" 2>/dev/null \
  && ok "track-less return (steps+agents present) routes to persist_chain" || ko "track-less heuristic" "misrouted"

# ===========================================================================
echo "D: malformed return rejected (exit != 0)"
echo "[1,2,3]" > "$SCRATCH/bad.json"
$PY "$PERSIST" --run-dir "$SCRATCH/run4" --return-file "$SCRATCH/bad.json" >/dev/null 2>&1
[ $? -ne 0 ] && ok "non-object return rejected" || ko "malformed reject" "accepted"

# ===========================================================================
echo "E: /resume single-chain next walks a chain manifest"
# happy chain (A) -> COMPLETE
NXT=$($PY "$RM" next "$RUN/manifest.json" 2>/dev/null)
[ "$NXT" = "COMPLETE" ] && ok "next = COMPLETE on a fully-complete chain" || ko "next complete" "got '$NXT'"
# surfaced chain (B) -> BLOCKED:<offending step> (blocked is terminal, surfaced ahead of pending)
NXT=$($PY "$RM" next "$RUN2/manifest.json" 2>/dev/null)
[ "$NXT" = "BLOCKED:02-security-auditor" ] && ok "next surfaces BLOCKED:<step> on a surfaced chain" || ko "next blocked" "got '$NXT'"
# fresh chain manifest -> first pending step
RUNE="$SCRATCH/rune"; mkdir -p "$RUNE"
$PY "$RM" init --run-dir "$RUNE" --slug e --track chain --chain "01-cto-advisor,02-implementer,03-code-reviewer" >/dev/null 2>&1
NXT=$($PY "$RM" next "$RUNE/manifest.json" 2>/dev/null)
[ "$NXT" = "01-cto-advisor" ] && ok "next = first pending step on a fresh chain manifest" || ko "next first" "got '$NXT'"
$PY -c "import json;m=json.load(open('$RUNE/manifest.json'));assert m['track']=='chain';assert 'tickets' not in m" 2>/dev/null \
  && ok "chain manifest has no tickets[] (single-chain, not orchestrated)" || ko "chain shape" "tickets present"

# ===========================================================================
echo "F: chain.js parses (node --check)"
if command -v node >/dev/null 2>&1; then
  node --check "$HERE/workflows/chain.js" 2>/dev/null && ok "chain.js parses clean" || ko "chain.js syntax" "node --check failed"
else
  ok "chain.js syntax (skipped — node not installed)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || { printf "%b\n" "$FAIL_DETAIL"; exit 1; }
