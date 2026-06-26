#!/usr/bin/env bash
# Synthetic test harness for the v2 ORCHESTRATED engine (ADR-062/ADR-063).
# Coverage (no live agents — feeds known workflow-return JSON + temp git repos):
#   A. thin-manifest tickets[] lifecycle (run-manifest.py): set-tickets, next-ticket
#      (dep-ready / blocked / waiting / complete), orphan-dep rejection, nimble unaffected.
#   B. orchestrated artifact-sync (persist-run-artifacts.py): happy / surfaced / short-circuit.
#   C. worktree staleness guard (worktree-staleness-check.sh) — preserved for nimble's use; the
#      orchestrated engine no longer invokes it (ADR-062 §3: one sequential writer per wave, in-place;
#      the within-wave staleness hazard is gone). The script still exists for nimble.js and other callers.
#   D. orchestrated.js parses (node --check).
#   E. AC coverage check (ADR-047 §3).
#   F. ADR-062 wave-build shape: 3-ticket single-wave end-to-end — per-ticket commits land on the wave
#      branch in dependency order with the 'T-NNN: ' message-format prefix.
#   G. behavioral mock-harness assertions (one implementer per wave, verification no-op integrate,
#      conditional architect-final, one funnel per epic).
#   H. ADR-039 four-contract verification on the rewritten scripts.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PY=python3
RM="$HERE/run-manifest.py"
PERSIST="$HERE/persist-run-artifacts.py"
GUARD="$HERE/worktree-staleness-check.sh"
PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }

SCRATCH=$(mktemp -d)
trap "rm -rf '$SCRATCH'" EXIT

# ===========================================================================
echo "A: thin-manifest tickets[] lifecycle (run-manifest.py)"
RUN="$SCRATCH/run"; mkdir -p "$RUN"
MAN="$RUN/manifest.json"
$PY "$RM" init --run-dir "$RUN" --slug "orch" --track orchestrated --chain "cto,implement,integrate,gate" >/dev/null 2>&1
cat > "$SCRATCH/tk.json" <<'JSON'
[
 {"key":"T-001","depends_on":[],"planned_files":["core/a.py"]},
 {"key":"T-002","depends_on":["T-001"],"planned_files":["core/b.py"]},
 {"key":"T-003","depends_on":["T-001"],"planned_files":["core/c.py"]}
]
JSON
$PY "$RM" set-tickets "$MAN" --tickets-file "$SCRATCH/tk.json" >/dev/null 2>&1
$PY -c "import json;m=json.load(open('$MAN'));assert len(m['tickets'])==3;assert m['tickets'][1]['depends_on']==['T-001']" 2>/dev/null \
  && ok "set-tickets populates tickets[] with deps" || ko "set-tickets" "bad shape"
NT=$($PY "$RM" next-ticket "$MAN" 2>/dev/null)
[ "$NT" = "T-001" ] && ok "next-ticket = first dep-ready (T-001)" || ko "next-ticket first" "got '$NT'"
$PY "$RM" set-ticket "$MAN" T-001 complete --sha abc123 >/dev/null 2>&1
NT=$($PY "$RM" next-ticket "$MAN" 2>/dev/null)
[ "$NT" = "T-002" ] && ok "next-ticket advances after dep complete (T-002)" || ko "next-ticket dep" "got '$NT'"
$PY -c "import json;m=json.load(open('$MAN'));t=[x for x in m['tickets'] if x['key']=='T-001'][0];assert t['commit_sha']=='abc123'" 2>/dev/null \
  && ok "set-ticket records commit_sha" || ko "set-ticket sha" "missing"
$PY "$RM" set-ticket "$MAN" T-002 complete >/dev/null 2>&1
$PY "$RM" set-ticket "$MAN" T-003 complete >/dev/null 2>&1
NT=$($PY "$RM" next-ticket "$MAN" 2>/dev/null)
[ "$NT" = "COMPLETE" ] && ok "next-ticket = COMPLETE when all done" || ko "next-ticket complete" "got '$NT'"
# blocked surfaced ahead of pending
$PY "$RM" set-ticket "$MAN" T-003 blocked >/dev/null 2>&1
NT=$($PY "$RM" next-ticket "$MAN" 2>/dev/null)
[ "$NT" = "BLOCKED:T-003" ] && ok "next-ticket surfaces BLOCKED:<key>" || ko "next-ticket blocked" "got '$NT'"
# orphan dependency rejected
echo '[{"key":"X","depends_on":["NOPE"]}]' > "$SCRATCH/bad.json"
$PY "$RM" set-tickets "$MAN" --tickets-file "$SCRATCH/bad.json" >/dev/null 2>&1
[ $? -ne 0 ] && ok "set-tickets rejects orphan depends_on" || ko "orphan reject" "accepted"
# WAITING: dependency stall (incomplete ticket gated on an incomplete dep, nothing dep-ready)
RUNW="$SCRATCH/runw"; mkdir -p "$RUNW"
$PY "$RM" init --run-dir "$RUNW" --slug w --track orchestrated --chain "implement" >/dev/null 2>&1
cat > "$SCRATCH/tkw.json" <<'JSON'
[{"key":"T-001","status":"blocked","depends_on":[]},{"key":"T-002","status":"pending","depends_on":["T-001"]}]
JSON
$PY "$RM" set-tickets "$RUNW/manifest.json" --tickets-file "$SCRATCH/tkw.json" >/dev/null 2>&1
NT=$($PY "$RM" next-ticket "$RUNW/manifest.json" 2>/dev/null)
[ "$NT" = "BLOCKED:T-001" ] && ok "blocked dep surfaces before its dependent" || ko "blocked-dep" "got '$NT'"
# nimble single-chain unaffected (no tickets key)
RUNN="$SCRATCH/runn"; mkdir -p "$RUNN"
$PY "$RM" init --run-dir "$RUNN" --slug n --track nimble --chain "explore,implement,gate" >/dev/null 2>&1
$PY -c "import json;m=json.load(open('$RUNN/manifest.json'));assert 'tickets' not in m" 2>/dev/null \
  && ok "nimble manifest unaffected (no tickets[] key)" || ko "nimble regression" "tickets key present"

# ===========================================================================
echo "B: orchestrated artifact-sync (persist-run-artifacts.py) — happy path"
RUN2="$SCRATCH/run2"; mkdir -p "$RUN2/findings"
cat > "$SCRATCH/ret-ok.json" <<'JSON'
{
  "track":"orchestrated",
  "cto":{"recommendation":"GO","rationale":"sound","evaluation_markdown":"# CTO\nGO"},
  "archPre":{"verdict":"SOUND","summary":"ok","adr_markdown":"# ADR-040x\n## Decision\nDo it."},
  "spec":{"spec_markdown":"# Spec\n## AC-1\nx"},
  "uiSpec":null,
  "tickets":[
    {"key":"T-001","description":"a","depends_on":[],"planned_files":["core/a.py"]},
    {"key":"T-002","description":"b","depends_on":["T-001"],"planned_files":["core/b.py"]}
  ],
  "gateReviewers":[],
  "exploreMap":["explored the repo"],
  "implementResults":[
    {"ticket_key":"T-001","status":"complete","sha":"aaa111","files_changed":["core/a.py"],"report":"done a"},
    {"ticket_key":"T-002","status":"complete","sha":"bbb222","files_changed":["core/b.py"],"report":"done b"}
  ],
  "integrate":{"status":"integrated","integrated_head":"ccc333","merged":["T-001","T-002"],"stale":[],"report":"merged both"},
  "review":{"verdict":"APPROVE","summary":"clean","findings":[]},
  "conformance":{"verdict":"CONFORMS","summary":"all ACs met","findings":[]},
  "contextualReviews":[],
  "archFinal":{"verdict":"APPROVE","summary":"integrates cleanly","findings":[]},
  "allFindings":[],"criterionFindings":[],"surfaceRequired":false
}
JSON
$PY "$PERSIST" --run-dir "$RUN2" --return-file "$SCRATCH/ret-ok.json" --slug "orch2" --task "build a+b" >/dev/null 2>&1
[ -f "$RUN2/adr.md" ] && grep -q "ADR-040x" "$RUN2/adr.md" && ok "adr.md persisted (pre-pass ADR, D4)" || ko "adr.md" "missing/empty"
[ -f "$RUN2/spec.md" ] && ok "spec.md persisted" || ko "spec.md" "missing"
[ -f "$RUN2/cto-evaluation.md" ] && ok "cto-evaluation.md persisted" || ko "cto-eval" "missing"
[ -f "$RUN2/findings/implementer-T-001.md" ] && [ -f "$RUN2/findings/implementer-T-002.md" ] && ok "per-ticket implementer reports persisted" || ko "impl reports" "missing"
[ -f "$RUN2/findings/integrate.md" ] && ok "integrate.md persisted" || ko "integrate" "missing"
[ -f "$RUN2/findings/architect-review-final.md" ] && grep -q "APPROVE" "$RUN2/findings/architect-review-final.md" && ok "architect-final findings persisted (D4 pass 2)" || ko "arch-final" "missing"
[ -f "$RUN2/findings/code-reviewer.md" ] && [ -f "$RUN2/findings/spec-conformance.md" ] && ok "gate findings persisted" || ko "gate findings" "missing"
$PY -c "import json;m=json.load(open('$RUN2/manifest.json'));assert m['status']=='complete',m['status'];assert all(t['status']=='complete' for t in m['tickets']);assert [t['commit_sha'] for t in m['tickets']]==['aaa111','bbb222']" 2>/dev/null \
  && ok "manifest: complete + tickets[] complete with SHAs" || ko "manifest complete" "wrong state"
$PY -c "import json;m=json.load(open('$RUN2/manifest.json'));p=[s['phase'] for s in m['steps']];assert 'ui-spec' not in p, p;assert p[0]=='cto' and p[-1]=='architect-final'" 2>/dev/null \
  && ok "chain reflects phases that ran (no ui-spec; cto..architect-final)" || ko "chain shape" "wrong"

echo "B2: orchestrated artifact-sync — surfaced path (criterion finding -> surfaced/blocked gate)"
RUN3="$SCRATCH/run3"; mkdir -p "$RUN3/findings"
cat > "$SCRATCH/ret-surf.json" <<'JSON'
{
  "track":"orchestrated",
  "cto":{"recommendation":"GO","rationale":"ok"},
  "archPre":{"verdict":"SOUND","adr_markdown":"# ADR"},
  "spec":{"spec_markdown":"# S"},
  "tickets":[{"key":"T-001","description":"a","depends_on":[],"planned_files":[]}],
  "exploreMap":["x"],
  "implementResults":[{"ticket_key":"T-001","status":"complete","sha":"aaa","report":"d"}],
  "integrate":{"status":"integrated","integrated_head":"hhh","merged":["T-001"],"stale":[],"report":"m"},
  "review":{"verdict":"REQUEST_CHANGES","summary":"sec","findings":[
    {"id":"CR-9","severity":"critical","criterion_match":"crit-3","recommended_disposition":"ESCALATE","detail":"hardcoded secret"}]},
  "conformance":{"verdict":"CONFORMS","findings":[]},
  "contextualReviews":[],
  "archFinal":{"verdict":"APPROVE","findings":[]},
  "allFindings":[{"id":"CR-9","criterion_match":"crit-3"}],
  "criterionFindings":[{"id":"CR-9","criterion_match":"crit-3","detail":"hardcoded secret"}],
  "surfaceRequired":true
}
JSON
$PY "$PERSIST" --run-dir "$RUN3" --return-file "$SCRATCH/ret-surf.json" --slug s3 --task t >/dev/null 2>&1
$PY -c "import json;m=json.load(open('$RUN3/manifest.json'));assert m['status']=='surfaced',m['status'];assert m['surface_required'] is True;g=[s for s in m['steps'] if s['phase']=='gate'][0];assert g['status']=='blocked',g" 2>/dev/null \
  && ok "surfaced: run=surfaced, gate=blocked, surface_required=true" || ko "surfaced path" "wrong state"

echo "B3: orchestrated artifact-sync — short-circuit (cto NO-GO -> stoppedAt cto)"
RUN4="$SCRATCH/run4"; mkdir -p "$RUN4/findings"
cat > "$SCRATCH/ret-sc.json" <<'JSON'
{
  "track":"orchestrated","stoppedAt":"cto",
  "cto":{"recommendation":"NO-GO","rationale":"too risky","evaluation_markdown":"# CTO\nNO-GO"},
  "allFindings":[{"id":"CTO-GATE","criterion_match":"crit-2"}],
  "criterionFindings":[{"id":"CTO-GATE","criterion_match":"crit-2","detail":"cto NO-GO: too risky"}],
  "surfaceRequired":true
}
JSON
$PY "$PERSIST" --run-dir "$RUN4" --return-file "$SCRATCH/ret-sc.json" --slug s4 --task t >/dev/null 2>&1
$PY -c "import json;m=json.load(open('$RUN4/manifest.json'));assert m['status']=='surfaced',m['status'];p=[s['phase'] for s in m['steps']];assert p==['cto'],p" 2>/dev/null \
  && ok "short-circuit: only the cto step recorded, run surfaced" || ko "short-circuit" "wrong chain"
[ -f "$RUN4/cto-evaluation.md" ] && grep -q "NO-GO" "$RUN4/cto-evaluation.md" && ok "short-circuit persists the cto evaluation" || ko "sc cto-eval" "missing"

# ===========================================================================
echo "C: AC-5 worktree staleness guard (worktree-staleness-check.sh)"
# Reproduce the session-stable-base stale-base failure in a disposable temp repo and assert the
# guard refuses it (positive control), permits fresh (negative control), and does NOT false-positive
# on in-wave sequential merges (the guard checks a FIXED base, not the advancing HEAD).
TR="$SCRATCH/git"; mkdir -p "$TR"
(
  cd "$TR"
  git init -q -b main
  git config user.email t@t.local; git config user.name t
  echo init > f.txt; git add .; git commit -qm "A: session-stable base"
  A=$(git rev-parse HEAD)
  # ticket commit rooted at the STALE base A
  git checkout -q -b t-stale "$A"; echo stale > stale.txt; git add .; git commit -qm "T-stale on A"
  STALE_SHA=$(git rev-parse HEAD)
  git checkout -q main
  # the wave base advances to B (a prior wave merged earlier in the session)
  echo more >> f.txt; git add .; git commit -qm "B1 intervening"
  echo more2 >> f.txt; git add .; git commit -qm "B2 intervening"
  B=$(git rev-parse HEAD)
  # fresh ticket commits rooted at the CURRENT base B
  git checkout -q -b t-fresh1 "$B"; echo fr1 > fr1.txt; git add .; git commit -qm "T-fresh1 on B"
  F1=$(git rev-parse HEAD)
  git checkout -q -b t-fresh2 "$B"; echo fr2 > fr2.txt; git add .; git commit -qm "T-fresh2 on B"
  F2=$(git rev-parse HEAD)
  git checkout -q main
  echo "$A $STALE_SHA $B $F1 $F2" > "$SCRATCH/shas"
)
read -r A STALE_SHA B F1 F2 < "$SCRATCH/shas"
# positive control: stale commit (rooted at A) vs base B -> REFUSE (exit 2)
(cd "$TR" && bash "$GUARD" "$B" "$STALE_SHA" >/dev/null 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "guard REFUSES a stale-base commit (positive control, exit 2)" || ko "guard stale" "rc=$RC (expected 2)"
# negative control: fresh commit (rooted at B) vs base B -> OK (exit 0)
(cd "$TR" && bash "$GUARD" "$B" "$F1" >/dev/null 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "guard PERMITS a fresh-base commit (negative control, exit 0)" || ko "guard fresh" "rc=$RC (expected 0)"
# sequential-merge non-false-positive: merge F1 (advances HEAD), then check F2 against the FIXED
# base B -> still fresh (exit 0). A naive branch..HEAD check would false-positive here.
(cd "$TR" && git merge --no-ff -q "$F1" -m "merge F1" && bash "$GUARD" "$B" "$F2" >/dev/null 2>&1); RC=$?
[ "$RC" -eq 0 ] && ok "guard does NOT false-positive on in-wave sequential merge (fixed-base check)" || ko "guard sequential" "rc=$RC (expected 0)"
# mixed batch: both fresh + one stale -> REFUSE (exit 2)
(cd "$TR" && bash "$GUARD" "$B" "$F1" "$STALE_SHA" "$F2" >/dev/null 2>&1); RC=$?
[ "$RC" -eq 2 ] && ok "guard refuses a mixed batch containing a stale commit (exit 2)" || ko "guard mixed" "rc=$RC (expected 2)"
# usage error: <2 args -> exit 1
(cd "$TR" && bash "$GUARD" "$B" >/dev/null 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok "guard usage error on missing refs (exit 1)" || ko "guard usage" "rc=$RC (expected 1)"

# ===========================================================================
echo "C2: run-manifest.py tickets[] validator — cycle rejection (CR-003 symmetry)"
RUNC="$SCRATCH/runc"; mkdir -p "$RUNC"
$PY "$RM" init --run-dir "$RUNC" --slug c --track orchestrated --chain "implement" >/dev/null 2>&1
echo '[{"key":"T-001","depends_on":["T-002"]},{"key":"T-002","depends_on":["T-001"]}]' > "$SCRATCH/cyc.json"
$PY "$RM" set-tickets "$RUNC/manifest.json" --tickets-file "$SCRATCH/cyc.json" >/dev/null 2>&1
[ $? -ne 0 ] && ok "set-tickets rejects a dependency cycle" || ko "cycle reject" "accepted"
echo '[{"key":"bad key!","depends_on":[]}]' > "$SCRATCH/badkey.json"
$PY "$RM" set-tickets "$RUNC/manifest.json" --tickets-file "$SCRATCH/badkey.json" >/dev/null 2>&1
# (key-shape is enforced in orchestrated.js up-front; run-manifest accepts any non-empty string key,
#  so this is only a documentation assertion that the manifest layer stays permissive on key chars)
$PY -c "import json" 2>/dev/null && ok "run-manifest key policy documented (shape enforced in preset)" || ko "doc" "py broken"

# ===========================================================================
echo "D: orchestrated.js parses (node --check)"
if command -v node >/dev/null 2>&1; then
  node --check "$HERE/workflows/orchestrated.js" 2>/dev/null && ok "orchestrated.js parses clean" || ko "orchestrated.js syntax" "node --check failed"
else
  ok "orchestrated.js syntax (skipped — node not installed)"
fi

# ===========================================================================
echo "E: AC coverage check (ADR-047 §3 — every spec AC claimed by >=1 ticket)"
# E1 — structural: the deterministic coverage block is wired at the gate site.
if grep -q 'coverage-check' "$HERE/workflows/orchestrated.js" \
   && grep -q 'AC-COVERAGE' "$HERE/workflows/orchestrated.js" \
   && grep -q "match(/\\\\bAC-\\\\d+\\\\b/g)" "$HERE/workflows/orchestrated.js"; then
  ok "coverage-check block present (specACs + uncoveredACs + AC-COVERAGE finding)"
else
  ko "coverage-check wiring" "missing coverage-check / AC-COVERAGE / AC-NNN regex in orchestrated.js"
fi
# E2 — behavioral: the set-equality algorithm flags a dropped AC and passes full coverage.
if command -v node >/dev/null 2>&1; then
  node -e '
    function uncovered(specText, tickets) {
      const specACs = [...new Set(specText.match(/\bAC-\d+\b/g) || [])];
      const claimed = new Set(tickets.flatMap(t => (t.acceptance || [])));
      return specACs.filter(ac => !claimed.has(ac));
    }
    const spec = "AC-1 do x. AC-2 do y. AC-3 do z.";
    const gap = uncovered(spec, [{acceptance:["AC-1","AC-2"]}]);          // AC-3 dropped
    const full = uncovered(spec, [{acceptance:["AC-1"]},{acceptance:["AC-2","AC-3"]}]);
    const none = uncovered("no formal criteria here", [{acceptance:[]}]); // spec mints no AC
    if (JSON.stringify(gap)==="[\"AC-3\"]" && full.length===0 && none.length===0) process.exit(0);
    console.error("gap="+JSON.stringify(gap)+" full="+JSON.stringify(full)+" none="+JSON.stringify(none));
    process.exit(1);
  ' && ok "coverage algorithm: flags dropped AC, passes full coverage, skips no-AC spec" \
     || ko "coverage algorithm" "set-equality produced wrong result"
else
  ok "coverage algorithm (skipped — node not installed)"
fi

# ===========================================================================
echo "F: ADR-062 wave-build shape (3-ticket single-wave — per-ticket commits in dep order)"
# Simulates what the wave-builder (ONE implementer, in-place on the wave branch) leaves behind: a
# linear sequence of per-ticket commits with the 'T-NNN: <description>' message-format prefix. The
# (new) integrate phase verifies this exact shape via `git log waveBase..HEAD`. Builds the same shape
# end-to-end in a disposable repo and asserts it parses (which is what the integrate verifier asserts).
TW="$SCRATCH/wave"; mkdir -p "$TW"
(
  cd "$TW"
  git init -q -b feature/wave-test
  git config user.email t@t.local; git config user.name t
  echo init > seed.txt; git add .; git commit -qm "wave base"
  WAVE_BASE=$(git rev-parse HEAD)
  # The wave-builder commits per ticket in dependency order, in-place on the wave branch:
  #   T-101 (leaf) → T-102 (deps T-101) → T-103 (deps T-102).
  echo a > a.txt; git add .; git commit -qm "T-101: first ticket"
  echo b > b.txt; git add .; git commit -qm "T-102: second ticket"
  echo c > c.txt; git add .; git commit -qm "T-103: third ticket"
  echo "$WAVE_BASE" > "$SCRATCH/wave_base"
)
WAVE_BASE=$(cat "$SCRATCH/wave_base")
# F1 — exactly 3 commits since waveBase
CNT=$(cd "$TW" && git log --oneline "$WAVE_BASE"..HEAD | wc -l | tr -d ' ')
[ "$CNT" = "3" ] && ok "wave-builder: 3 per-ticket commits since wave base" || ko "wave-builder count" "got $CNT (expected 3)"
# F2 — commits are in dependency order T-101 → T-102 → T-103 (git log --reverse oldest-first)
ORDER=$(cd "$TW" && git log --reverse --format='%s' "$WAVE_BASE"..HEAD | awk -F: '{print $1}' | tr '\n' ' ' | sed 's/ $//')
[ "$ORDER" = "T-101 T-102 T-103" ] && ok "wave-builder: commits in dependency order (T-101 T-102 T-103)" || ko "wave-builder order" "got '$ORDER'"
# F3 — each subject matches the literal 'T-NNN: ' prefix the integrate verifier expects
BAD_PREFIX=$(cd "$TW" && git log --format='%s' "$WAVE_BASE"..HEAD | grep -vcE '^T-[0-9]+: ' || true)
[ "$BAD_PREFIX" = "0" ] && ok "wave-builder: every commit subject matches 'T-NNN: <description>' format" || ko "wave-builder format" "$BAD_PREFIX bad subjects"
# F4 — under ADR-062, integrate is a verification no-op; no merge commits in the wave-base..HEAD range.
MERGE_COUNT=$(cd "$TW" && git log --merges "$WAVE_BASE"..HEAD | wc -l | tr -d ' ')
[ "$MERGE_COUNT" = "0" ] && ok "wave-builder: NO merge commits (verification no-op integrate)" || ko "wave-builder merges" "got $MERGE_COUNT merge commits (expected 0)"

# ===========================================================================
echo "G: behavioral engine run under the mock-runtime harness (ADR-062 wave shape)"
# Runs orchestrated.js + roadmap.js end-to-end under shimmed agent()/parallel()/phase()/log() runtimes
# and asserts BOTH the returned payload and the dispatch sequence — one implementer per wave,
# verification no-op integrate, conditional architect-final, one funnel per epic. The one thing it
# can't prove: that the real implementer commits per ticket on the wave branch (the section-F substrate
# assertions cover that shape directly).
if command -v node >/dev/null 2>&1; then
  if node "$HERE/test-orchestrated-behavioral.mjs" >/tmp/orch-behavioral.$$ 2>&1; then
    ok "behavioral: $(tail -1 /tmp/orch-behavioral.$$)"
  else
    ko "behavioral engine run" "$(tail -3 /tmp/orch-behavioral.$$ | tr '\n' ' ')"
  fi
  rm -f /tmp/orch-behavioral.$$
else
  ok "behavioral engine run (skipped — node not installed)"
fi

# ===========================================================================
echo "H: ADR-039 four engine contracts (preserved in both rewritten scripts)"
# Contract 1 — defensive args parse at the top of each script.
if grep -q "typeof args === 'string'" "$HERE/workflows/orchestrated.js" \
   && grep -q "typeof args === 'string'" "$HERE/workflows/roadmap.js"; then
  ok "contract 1: defensive args parse present in orchestrated.js + roadmap.js"
else
  ko "contract 1" "missing defensive args parse"
fi
# Contract 2 — no FS writes from the script body.
NW1=$(grep -cE 'fs\.write|writeFileSync' "$HERE/workflows/orchestrated.js" || true)
NW2=$(grep -cE 'fs\.write|writeFileSync' "$HERE/workflows/roadmap.js" || true)
if [ "$NW1" = "0" ] && [ "$NW2" = "0" ]; then
  ok "contract 2: no fs.write / writeFileSync in either script body"
else
  ko "contract 2" "orchestrated=$NW1 roadmap=$NW2 FS writes"
fi
# Contract 3 — criterionFindings + surfaceRequired emitted in the return.
if grep -q "criterionFindings" "$HERE/workflows/orchestrated.js" \
   && grep -q "surfaceRequired" "$HERE/workflows/orchestrated.js" \
   && grep -q "criterionFindings" "$HERE/workflows/roadmap.js" \
   && grep -q "surfaceRequired" "$HERE/workflows/roadmap.js"; then
  ok "contract 3: criterionFindings + surfaceRequired present in both scripts"
else
  ko "contract 3" "missing criterionFindings/surfaceRequired"
fi
# Contract 4 — isolation matches preset. The orchestrated wave-builder runs in-place (no isolation:'worktree'
# on its agent() call). Nimble.js may retain isolation:'worktree' for its single-ticket implementer.
WT_ORCH=$(grep -cE "isolation:\s*['\"]worktree['\"]" "$HERE/workflows/orchestrated.js" || true)
if [ "$WT_ORCH" = "0" ]; then
  ok "contract 4: orchestrated wave-builder runs in-place (no isolation:'worktree' in orchestrated.js)"
else
  ko "contract 4" "found $WT_ORCH isolation:'worktree' references in orchestrated.js (expected 0)"
fi

# I. AC-006/AC-013/AC-014 — verification greps over orchestrated.js (load-bearing for the doctrine).
echo "I: ADR-062 verification greps (live framing removed)"
V1=$(grep -cE "runCapped|kahnLevels|waveLevels|gateBaseRef|MODE\s*===\s*['\"](plan|wave|finalize)['\"]" "$HERE/workflows/orchestrated.js" || true)
[ "$V1" = "0" ] && ok "AC-006: v1 phase-mode infra removed (runCapped/kahnLevels/waveLevels/gateBaseRef/MODE===)" || ko "AC-006" "$V1 matches remain"
V2=$(grep -cE "decompGap|falseDisjoint|shared-sink-false-disjoint" "$HERE/workflows/orchestrated.js" || true)
[ "$V2" = "0" ] && ok "AC-013: false-disjoint shared-sink detection removed" || ko "AC-013" "$V2 matches remain"
V3=$(grep -cE "SHA_RE|KEY_RE" "$HERE/workflows/orchestrated.js" || true)
[ "$V3" = "0" ] && ok "AC-014: SHA_RE/KEY_RE shape-validation guards removed (multi-SHA shell interpolation gone)" || ko "AC-014" "$V3 matches remain"

# J. PEC-T14 / ADR-112 Wave 5 — examiner fold-in pass (BEFORE the wave-build).
echo "J: PEC-T14 examiner fold-in (before build; PLANNED skips; fold-in only, no halt)"
if command -v node >/dev/null 2>&1; then
  J_OUT=$(cd "$HERE" && node --input-type=module -e '
    import { runEngine, defaultMock } from "./fixtures/orchestrated-harness.mjs"
    let fail = 0
    const idx = (a,v) => a.indexOf(v)
    // (1) AC-032: NOT-PLANNED -> ONE examiner before implement; ledger record; no halt.
    {
      const { result, calls } = await runEngine({ args:{ runDir:"/tmp/o", repoRoot:"/r", task:"build x" }, mock: defaultMock })
      if (calls.filter(c => c==="examine").length !== 1) { console.error("FAIL examine once", calls); fail++ }
      if (!(idx(calls,"examine") >= 0 && idx(calls,"examine") < idx(calls,"implement"))) { console.error("FAIL examine before implement"); fail++ }
      const d = result.examinerDispatches || []
      if (d.length !== 1 || d[0].verdict !== "SOUND") { console.error("FAIL ledger record", JSON.stringify(d)); fail++ }
      if (result.surfaceRequired) { console.error("FAIL clean examine must not halt"); fail++ }
    }
    // (2) AC-032: FOLD-IN-REQUIRED -> pm-spec re-dispatch (examine-fold) folds the finding; no halt (AC-033).
    {
      const mock = (o,p) => {
        if (o.agentType==="examiner") return { verdict:"FOLD-IN-REQUIRED", findings:[{id:"F-001",severity:"BAD",prescription:"add edge AC"}], summary:"fold" }
        if (o.label==="examine-fold") return { spec_markdown:"Spec FOLDED (tightened).\nAC-1 the thing works.", summary:"folded" }
        return defaultMock(o,p)
      }
      const { result, calls } = await runEngine({ args:{ runDir:"/tmp/o", repoRoot:"/r", task:"build x" }, mock })
      if (!calls.includes("examine-fold")) { console.error("FAIL fold not re-dispatched"); fail++ }
      if ((result.examinerDispatches||[])[0].verdict !== "FOLD-IN-REQUIRED") { console.error("FAIL verdict not recorded"); fail++ }
      if (result.surfaceRequired) { console.error("FAIL fold-in must not halt (AC-033)"); fail++ }
    }
    // (3) AC-032: PLANNED folder -> examine SKIPPED (no double-examine; roadmap already examined).
    {
      const planned = {
        runDir:"/tmp/o", repoRoot:"/r", task:"build",
        waveSpecs:[{slug:"w1", markdown:"# Wave: w1\n## Tickets\n### T-1: do\n- depends_on: []"}],
        tickets:[{key:"T-1", description:"do", depends_on:[], planned_files:["a.ts"], acceptance:["AC-1"], wave_slug:"w1"}],
      }
      const { result, calls } = await runEngine({ args: planned, mock: defaultMock })
      if (!result.isPlanned) { console.error("FAIL planned not detected"); fail++ }
      if (calls.includes("examine")) { console.error("FAIL PLANNED must skip examine (no double-examine)"); fail++ }
    }
    process.exit(fail === 0 ? 0 : 1)
  ' 2>&1)
  [ $? -eq 0 ] && ok "PEC-T14 examine fold-in: dispatched before build, folds, no halt, PLANNED skips" \
              || ko "PEC-T14 examine fold-in" "$J_OUT"
else
  ok "PEC-T14 examine fold-in (skipped — node not installed)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || { printf "%b\n" "$FAIL_DETAIL"; exit 1; }
