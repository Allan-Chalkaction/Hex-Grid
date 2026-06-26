#!/usr/bin/env bash
# Synthetic test harness for the v2 nimble engine core (T5a).
# Coverage: thin manifest (run-manifest.py) + orchestrator-side artifact-sync
# (persist-run-artifacts.py — the FLAG-1 piece). No live agents; feeds a known
# workflow-return JSON and asserts the run folder is correctly materialized.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PY=python3
PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }

SCRATCH=$(mktemp -d)
trap "rm -rf '$SCRATCH'" EXIT

RUN="$SCRATCH/run"
mkdir -p "$RUN"

# ---------------------------------------------------------------------------
echo "AC: thin manifest init + lifecycle (run-manifest.py)"
MAN="$RUN/manifest.json"
$PY "$HERE/run-manifest.py" init --run-dir "$RUN" --slug "test-slug" --track nimble --chain "explore,implement,integrate,gate" >/dev/null 2>&1
[ -f "$MAN" ] && ok "init writes manifest.json" || ko "init writes manifest.json" "missing"
$PY -c "import json;m=json.load(open('$MAN'));assert m['schema']=='thin-manifest/1';assert m['status']=='running';assert [s['phase'] for s in m['steps']]==['explore','implement','integrate','gate'];assert all(s['status']=='pending' for s in m['steps'])" 2>/dev/null \
  && ok "init schema + pending steps (incl. integrate, ADR-046)" || ko "init schema + pending steps" "bad shape"
NXT=$($PY "$HERE/run-manifest.py" next "$MAN" 2>/dev/null)
[ "$NXT" = "explore" ] && ok "next = first pending (explore)" || ko "next" "got '$NXT'"
$PY "$HERE/run-manifest.py" set-step "$MAN" explore complete >/dev/null 2>&1
NXT=$($PY "$HERE/run-manifest.py" next "$MAN" 2>/dev/null)
[ "$NXT" = "implement" ] && ok "next advances after complete" || ko "next advances" "got '$NXT'"
$PY "$HERE/run-manifest.py" set-step "$MAN" implement complete >/dev/null 2>&1
NXT=$($PY "$HERE/run-manifest.py" next "$MAN" 2>/dev/null)
[ "$NXT" = "integrate" ] && ok "next = integrate after implement (ADR-046)" || ko "next integrate" "got '$NXT'"
$PY "$HERE/run-manifest.py" set-step "$MAN" integrate complete >/dev/null 2>&1
$PY "$HERE/run-manifest.py" set-step "$MAN" gate complete >/dev/null 2>&1
NXT=$($PY "$HERE/run-manifest.py" next "$MAN" 2>/dev/null)
[ "$NXT" = "COMPLETE" ] && ok "next = COMPLETE when all done" || ko "next COMPLETE" "got '$NXT'"
# invalid status rejected
$PY "$HERE/run-manifest.py" set-status "$MAN" bogus >/dev/null 2>&1
[ $? -ne 0 ] && ok "invalid run status rejected (exit!=0)" || ko "invalid status" "accepted"

# ---------------------------------------------------------------------------
echo "AC: artifact-sync happy path (persist-run-artifacts.py — FLAG 1)"
RUN2="$SCRATCH/run2"; mkdir -p "$RUN2"
RET="$SCRATCH/return-ok.json"
cat > "$RET" <<'JSON'
{
  "exploreMap": ["explore finding A", "explore finding B"],
  "implementation": "COMPLETION_REPORT: created core/scripts/foo.sh; 5/5 ACs pass.",
  "integrate": {"status":"integrated","integrated_head":"abc1234","base_sha":"def5678","report":"merged --no-ff, clean"},
  "review": {"verdict":"APPROVE","summary":"clean","findings":[
     {"id":"CR-001","severity":"nit","criterion_match":"none","recommended_disposition":"DISMISS","detail":"a nit"}]},
  "conformance": {"verdict":"CONFORMS","summary":"all ACs satisfied","findings":[]},
  "allFindings": [{"id":"CR-001","criterion_match":"none"}],
  "criterionFindings": [],
  "surfaceRequired": false
}
JSON
OUT=$($PY "$HERE/persist-run-artifacts.py" --run-dir "$RUN2" --return-file "$RET" --slug "test-slug" --task "build foo.sh" 2>&1)
[ -f "$RUN2/findings/explore-1.md" ] && [ -f "$RUN2/findings/explore-2.md" ] && ok "explore findings written (1 per agent)" || ko "explore findings" "missing"
[ -f "$RUN2/findings/implementer.md" ] && ok "implementer.md written" || ko "implementer.md" "missing"
{ [ -f "$RUN2/findings/integrate.md" ] && grep -q "integrated" "$RUN2/findings/integrate.md" && grep -q "abc1234" "$RUN2/findings/integrate.md"; } \
  && ok "integrate.md written + integrated_head captured (ADR-046)" || ko "integrate.md" "missing or no integrated_head"
[ -f "$RUN2/findings/code-reviewer.md" ] && ok "code-reviewer.md written" || ko "code-reviewer.md" "missing"
[ -f "$RUN2/findings/spec-conformance.md" ] && ok "spec-conformance.md written" || ko "spec-conformance.md" "missing"
[ -f "$RUN2/run-log.md" ] && ok "run-log.md written" || ko "run-log.md" "missing"
[ -f "$RUN2/manifest.json" ] && ok "manifest.json written" || ko "manifest.json" "missing"
grep -q "APPROVE" "$RUN2/findings/code-reviewer.md" && ok "code-reviewer verdict captured" || ko "verdict captured" "no APPROVE"
grep -q "create core/scripts/foo.sh\|created core/scripts/foo.sh" "$RUN2/findings/implementer.md" && ok "implementer report captured" || ko "impl captured" "missing body"
# manifest reflects complete + not surfaced
$PY -c "import json;m=json.load(open('$RUN2/manifest.json'));assert m['status']=='complete',m['status'];assert all(s['status']=='complete' for s in m['steps'])" 2>/dev/null \
  && ok "manifest: complete, all steps complete" || ko "manifest complete" "wrong status"

# ---------------------------------------------------------------------------
echo "AC: artifact-sync surfaced path (criterion findings -> blocked gate)"
RUN3="$SCRATCH/run3"; mkdir -p "$RUN3"
RET2="$SCRATCH/return-surface.json"
cat > "$RET2" <<'JSON'
{
  "exploreMap": ["x"],
  "implementation": "COMPLETION_REPORT: partial.",
  "review": {"verdict":"REQUEST_CHANGES","summary":"security issue","findings":[
     {"id":"CR-009","severity":"critical","criterion_match":"crit-3","recommended_disposition":"ESCALATE","detail":"hardcoded secret"}]},
  "conformance": {"verdict":"DRIFT","summary":"missing AC","findings":[]},
  "allFindings": [{"id":"CR-009","criterion_match":"crit-3"}],
  "criterionFindings": [{"id":"CR-009","criterion_match":"crit-3","detail":"hardcoded secret"}],
  "surfaceRequired": true
}
JSON
$PY "$HERE/persist-run-artifacts.py" --run-dir "$RUN3" --return-file "$RET2" --slug "s3" --task "t" >/dev/null 2>&1
$PY -c "import json;m=json.load(open('$RUN3/manifest.json'));assert m['status']=='surfaced',m['status'];assert m['surface_required'] is True;g=[s for s in m['steps'] if s['phase']=='gate'][0];assert g['status']=='blocked',g" 2>/dev/null \
  && ok "surfaced: run=surfaced, gate=blocked, surface_required=true" || ko "surfaced path" "wrong manifest state"
grep -q "REQUEST_CHANGES" "$RUN3/run-log.md" && grep -q "surface required: \*\*True\*\*" "$RUN3/run-log.md" && ok "run-log reflects surface" || ko "run-log surface" "missing"

# ---------------------------------------------------------------------------
echo "AC: idempotence (re-run overwrites deterministically)"
B1=$(cat "$RUN2/findings/implementer.md")
$PY "$HERE/persist-run-artifacts.py" --run-dir "$RUN2" --return-file "$RET" --slug "test-slug" --task "build foo.sh" >/dev/null 2>&1
B2=$(cat "$RUN2/findings/implementer.md")
[ "$B1" = "$B2" ] && ok "re-run is idempotent" || ko "idempotence" "content changed"

# ---------------------------------------------------------------------------
echo "AC: malformed return rejected (exit != 0)"
echo "[1,2,3]" > "$SCRATCH/bad.json"
$PY "$HERE/persist-run-artifacts.py" --run-dir "$SCRATCH/run4" --return-file "$SCRATCH/bad.json" >/dev/null 2>&1
[ $? -ne 0 ] && ok "non-object return rejected" || ko "malformed reject" "accepted"

# ---------------------------------------------------------------------------
echo "AC: contextual gate findings are persisted, not dropped (CR-001)"
RUN5="$SCRATCH/run5"; mkdir -p "$RUN5"
RET5="$SCRATCH/return-ctx.json"
cat > "$RET5" <<'JSON'
{
  "exploreMap": ["x"],
  "implementation": "COMPLETION_REPORT: ok.",
  "review": {"verdict":"APPROVE","summary":"ok","findings":[]},
  "conformance": {"verdict":"CONFORMS","summary":"ok","findings":[]},
  "contextualReview": {"verdict":"APPROVE","summary":"no auth issues","findings":[
     {"id":"SA-001","severity":"low","criterion_match":"none","recommended_disposition":"DISMISS","detail":"uses env var, good"}]},
  "contextualType": "security-auditor",
  "allFindings": [], "criterionFindings": [], "surfaceRequired": false
}
JSON
$PY "$HERE/persist-run-artifacts.py" --run-dir "$RUN5" --return-file "$RET5" --slug s5 --task t >/dev/null 2>&1
[ -f "$RUN5/findings/security-auditor.md" ] && grep -q "no auth issues" "$RUN5/findings/security-auditor.md" \
  && ok "contextual gate (security-auditor) findings persisted" || ko "contextual persisted" "missing security-auditor.md"

# ---------------------------------------------------------------------------
echo "AC: gate-died (null review/conformance) -> blocked, not complete (CR-002)"
RUN6="$SCRATCH/run6"; mkdir -p "$RUN6"
RET6="$SCRATCH/return-died.json"
cat > "$RET6" <<'JSON'
{
  "exploreMap": ["x"],
  "implementation": "COMPLETION_REPORT: ok.",
  "review": null,
  "conformance": null,
  "allFindings": [], "criterionFindings": [], "surfaceRequired": false
}
JSON
$PY "$HERE/persist-run-artifacts.py" --run-dir "$RUN6" --return-file "$RET6" --slug s6 --task t >/dev/null 2>&1
$PY -c "import json;m=json.load(open('$RUN6/manifest.json'));assert m['status']=='blocked',m['status'];g=[s for s in m['steps'] if s['phase']=='gate'][0];assert g['status']=='blocked',g;assert 'died' in (g['note'] or '')" 2>/dev/null \
  && ok "gate-died -> run blocked + gate blocked + note" || ko "gate-died blocked" "wrong state"

# ---------------------------------------------------------------------------
echo "AC: next emits BLOCKED:<phase> for a blocked step (CR-003)"
$PY -c "import json;p='$RUN6/manifest.json'" 2>/dev/null
NXT=$($PY "$HERE/run-manifest.py" next "$RUN6/manifest.json" 2>/dev/null)
[ "$NXT" = "BLOCKED:gate" ] && ok "next = BLOCKED:gate" || ko "next blocked token" "got '$NXT'"

# ---------------------------------------------------------------------------
echo "AC: init fails closed on an existing manifest unless --force (CR-005)"
$PY "$HERE/run-manifest.py" init --run-dir "$RUN6" --slug s6 --track nimble --chain "explore,implement,gate" >/dev/null 2>&1
RC=$?
[ $RC -ne 0 ] && ok "init refuses to clobber existing manifest" || ko "init guard" "clobbered (rc=$RC)"
$PY "$HERE/run-manifest.py" init --run-dir "$RUN6" --slug s6 --track nimble --chain "explore" --force >/dev/null 2>&1
[ $? -eq 0 ] && ok "init --force overwrites" || ko "init --force" "rejected"

# ---------------------------------------------------------------------------
echo "AC: set-status complete clears a prior surface_required (CR-004)"
RUN7="$SCRATCH/run7"; mkdir -p "$RUN7"
$PY "$HERE/run-manifest.py" init --run-dir "$RUN7" --slug s7 --track nimble --chain "explore,gate" >/dev/null 2>&1
$PY "$HERE/run-manifest.py" set-status "$RUN7/manifest.json" surfaced >/dev/null 2>&1
$PY "$HERE/run-manifest.py" set-status "$RUN7/manifest.json" complete >/dev/null 2>&1
$PY -c "import json;m=json.load(open('$RUN7/manifest.json'));assert m['surface_required'] is False,m" 2>/dev/null \
  && ok "complete clears surface_required" || ko "surface reset" "still true"

# ---------------------------------------------------------------------------
echo "AC: nimble.js dispatches the implementer in a worktree + integrates (ADR-046)"
NJS="$HERE/workflows/nimble.js"
if [ -f "$NJS" ]; then
  grep -q "isolation: 'worktree'" "$NJS" \
    && ok "implementer dispatched isolation:'worktree' (block-source-edits.sh allows worktree writes)" \
    || ko "worktree isolation" "nimble.js implement step is not isolation:'worktree'"
  grep -q "phase('integrate')" "$NJS" \
    && ok "integrate phase present" || ko "integrate phase" "no phase('integrate') in nimble.js"
  grep -qF 'echo .claude || echo core' "$NJS" \
    && ok "staleness-check path is consumer-safe self-detect (ADR-031)" \
    || ko "staleness path" "integrate uses a bare core/ path (breaks in consumers)"
  # the in-place anti-pattern must be gone
  grep -q "do NOT create a git worktree" "$NJS" \
    && ko "in-place residue" "nimble.js still instructs in-place (do NOT create a git worktree)" \
    || ok "no in-place-implement residue"
else
  ko "nimble.js structural" "workflows/nimble.js not found at $NJS"
fi

# ---------------------------------------------------------------------------
echo "AC-008: nimble-via-Workflow launching-context isolation (SHR3-T3 / ADR-046)"
# When nimble is launched from an autonomous BACKGROUND context (queue-chew / background Workflow), the
# launching session's interactive HEAD must NOT be flipped by integrate. nimble.js accepts a `workTree` arg
# and SCOPES the integrate git ops to it (`git -C <workTree>`) so the merge lands on the launching actor's
# isolated worktree, never the operator's tree. Absent => interactive in-place (unchanged).
if [ -f "$NJS" ]; then
  grep -q "_a.workTree" "$NJS" \
    && ok "nimble.js reads an optional workTree arg (launching-context worktree)" \
    || ko "workTree arg" "nimble.js does not read _a.workTree"
  # The integrate git ops are SCOPED via `git -C "<workTree>"` when surfaced (the GC prefix).
  grep -qF 'git -C "${safeWorkTree}"' "$NJS" \
    && ok "integrate scopes git ops to the launching worktree (git -C <workTree>) — launching HEAD untouched" \
    || ko "integrate scope" "integrate does not scope git to safeWorkTree (launching HEAD would flip)"
  # workTree is shape-guarded before interpolation (no shell breakout into the integrate command).
  grep -q "WORKTREE_RE" "$NJS" \
    && ok "workTree is shape-guarded before it reaches the integrate shell command (CR-001 parity)" \
    || ko "workTree guard" "no shape guard on workTree before shell interpolation"
  # The isolation decision rides the returned payload (audit, no new write path).
  grep -q "integrateIsolation" "$NJS" \
    && ok "launching-context isolation decision rides the returned payload (integrateIsolation audit)" \
    || ko "isolation audit" "no integrateIsolation on the payload"
  # ADR-062 §3 NON-GOAL: the orchestrated in-place wave-builder is NOT isolated — nimble's workTree scoping
  # is the autonomous-actor path only. Assert the comment cites the boundary so a reviewer doesn't add it.
  grep -q "ADR-062 §3" "$NJS" \
    && ok "ADR-062 §3 non-goal cited (orchestrated in-place builder stays unisolated by design)" \
    || ko "ADR-062 §3 cite" "the launching-isolation comment does not cite the ADR-062 §3 non-goal"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || { printf "%b\n" "$FAIL_DETAIL"; exit 1; }
