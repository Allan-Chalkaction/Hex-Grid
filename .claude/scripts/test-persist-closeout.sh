#!/usr/bin/env bash
# Synthetic harness for the SHR3-T1 auto-close-out wiring in persist-run-artifacts.py.
# Proves the deterministic completion step: a TERMINAL-COMPLETE persist auto-fires
# closeout-run.py's MOVE (the run leaves step-5-pipeline/ for step-6-done/) WITHOUT
# the orchestrator invoking the close-out verb — the gap AC-001 closes.
#
# Coverage (the three ACs):
#   AC-001 — persist's terminal-completion branch CALLS close-out and the call FIRES
#            (the run actually moves to docs/step-6-done/). A bare definition is not enough.
#   AC-002 — idempotent + fail-open: a second persist on the already-moved run is a no-op
#            (exit 0, persist does not crash); a malformed-manifest run warns + continues
#            (persist completes, exit 0).
#   AC-003 — OUT-bookend scope gate honored: an INCOMPLETE ticket refluxes to
#            docs/step-1-ideas/from-<run>/ and HOLDs the move (run stays in pipeline;
#            the HELD outcome is surfaced, not silently wrapped clean).
#   X      — terminal-ONLY: a SURFACED (non-complete) run does NOT fire the move.
#
# Each case runs in a throwaway git repo with copies of the scripts under test, so the
# real repo tree is never touched. Exit 0 = all PASS; exit 1 = a FAIL.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PERSIST="${REPO_ROOT}/core/scripts/persist-run-artifacts.py"
CLOSEOUT="${REPO_ROOT}/core/scripts/closeout-run.py"
RM="${REPO_ROOT}/core/scripts/run-manifest.py"
for f in "$PERSIST" "$CLOSEOUT" "$RM"; do [ -f "$f" ] || { echo "ERROR: $f not found" >&2; exit 1; }; done

PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }

# mk_repo → echoes a temp git repo dir containing copies of the scripts under core/scripts/.
mk_repo() {
  local d; d=$(mktemp -d)
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t
    mkdir -p core/scripts docs/step-5-pipeline docs/step-6-done docs/step-1-ideas
    cp "$PERSIST" "$CLOSEOUT" "$RM" core/scripts/
    git add -A >/dev/null 2>&1 && git commit -qm init )
  echo "$d"
}

# seed_run <repo> <run-rel> <manifest-json> <return-json>
#   Creates the run folder with a pre-built manifest.json (the scope gate reads it) and
#   writes the return file. Returns nothing; the caller drives persist.
seed_run() {
  local repo="$1" run_rel="$2" manifest="$3" ret="$4"
  mkdir -p "$repo/$run_rel"
  printf '%s' "$manifest" > "$repo/$run_rel/manifest.json"
  printf '%s' "$ret" > "$repo/$run_rel/_return.json"
  printf '# run\n' > "$repo/$run_rel/run-log.md"
  ( cd "$repo" && git add -A >/dev/null 2>&1 && git commit -qm seed )
}

# drive persist (track=orchestrated, --no-manifest so our pre-seeded manifest survives)
drive() {  # drive <repo> <run-rel>
  ( cd "$1" && python3 core/scripts/persist-run-artifacts.py \
      --run-dir "$2" --return-file "$2/_return.json" --no-manifest 2>&1 )
}

DATE="2026-06-14"

# A complete orchestrated return: one ticket merged + both gates clean → run_status=="complete".
COMPLETE_RET='{"track":"orchestrated",
  "tickets":[{"key":"T-001","depends_on":[],"planned_files":["core/a.py"],"acceptance":["AC-1"]}],
  "implementResults":[{"ticket_key":"T-001","status":"complete","sha":"abc","files_changed":["core/a.py"]}],
  "integrate":{"status":"ok","integrated_head":"abc","merged":["T-001"],"stale":[]},
  "review":{"verdict":"PASS","summary":"ok","findings":[]},
  "conformance":{"verdict":"PASS","summary":"ok","findings":[]},
  "allFindings":[],"criterionFindings":[],"surfaceRequired":false}'
# Manifest mirroring the complete state (the scope gate reads THIS, not the return).
COMPLETE_MAN='{"schema":"thin-manifest/1","slug":"s","track":"orchestrated","tickets":[
  {"key":"T-001","status":"complete","commit_sha":"abc","planned_files":["core/a.py"],"acceptance":["AC-1"]}]}'

# A surfaced return: a criterion finding forces surfaceRequired → run_status=="surfaced" (NOT complete).
SURFACED_RET='{"track":"orchestrated",
  "tickets":[{"key":"T-001","depends_on":[],"planned_files":["core/a.py"],"acceptance":["AC-1"]}],
  "implementResults":[{"ticket_key":"T-001","status":"complete","sha":"abc","files_changed":["core/a.py"]}],
  "integrate":{"status":"ok","integrated_head":"abc","merged":["T-001"],"stale":[]},
  "review":{"verdict":"CHANGES","summary":"x","findings":[{"id":"F1","criterion_match":"crit-1"}]},
  "conformance":{"verdict":"PASS","summary":"ok","findings":[]},
  "allFindings":[{"id":"F1"}],"criterionFindings":[{"id":"F1","criterion_match":"crit-1"}],"surfaceRequired":true}'

# A gap return: T-002 never reached complete → the scope gate HOLDs the move (exit 3).
GAP_RET='{"track":"orchestrated",
  "tickets":[{"key":"T-001","depends_on":[],"planned_files":["core/a.py"],"acceptance":["AC-1"]},
             {"key":"T-002","depends_on":[],"planned_files":["core/b.py"],"acceptance":["AC-2"]}],
  "implementResults":[{"ticket_key":"T-001","status":"complete","sha":"abc","files_changed":["core/a.py"]},
                      {"ticket_key":"T-002","status":"complete","sha":"def","files_changed":["core/b.py"]}],
  "integrate":{"status":"ok","integrated_head":"def","merged":["T-001","T-002"],"stale":[]},
  "review":{"verdict":"PASS","summary":"ok","findings":[]},
  "conformance":{"verdict":"PASS","summary":"ok","findings":[]},
  "allFindings":[],"criterionFindings":[],"surfaceRequired":false}'
# Manifest with a GAP: T-002 status=pending so verify_scope refluxes + holds.
GAP_MAN='{"schema":"thin-manifest/1","slug":"s","track":"orchestrated","tickets":[
  {"key":"T-001","status":"complete","commit_sha":"abc","planned_files":["core/a.py"],"acceptance":["AC-1"]},
  {"key":"T-002","status":"pending","commit_sha":null,"planned_files":["core/b.py"],"acceptance":["AC-2"]}]}'

# ---- AC-001: terminal-complete persist FIRES the move (run leaves pipeline → step-6-done) ----
D=$(mk_repo)
RUN="docs/step-5-pipeline/${DATE}/1500-WAVE-complete"
seed_run "$D" "$RUN" "$COMPLETE_MAN" "$COMPLETE_RET"
out=$(drive "$D" "$RUN"); rc=$?
moved_to="$D/docs/step-6-done/${DATE}/1500-WAVE-complete"
if [ "$rc" -eq 0 ] && [ -d "$moved_to" ] \
   && [ ! -d "$D/$RUN" ] \
   && echo "$out" | grep -q "closeout=moved"; then
  ok "AC-001: terminal-complete persist auto-fires close-out (run moved to step-6-done; invocation fired)"
else
  ko "AC-001 fires" "rc=$rc moved=$([ -d "$moved_to" ] && echo yes || echo no) src_gone=$([ ! -d "$D/$RUN" ] && echo yes || echo no) fired=$(echo "$out" | grep -q closeout=moved && echo yes || echo no)"
fi
# The CLOSED line was appended (stage-only close-out ran in full).
if grep -q "CLOSED:" "$moved_to/run-log.md" 2>/dev/null; then ok "AC-001: close-out appended its CLOSED line (full close-out ran, not a stub)"; else ko "AC-001 closed line" "no CLOSED line in moved run-log"; fi
rm -rf "$D"

# ---- X: a SURFACED (non-complete) persist does NOT fire the move (terminal-only) ----
D=$(mk_repo)
RUN="docs/step-5-pipeline/${DATE}/1501-WAVE-surfaced"
seed_run "$D" "$RUN" "$COMPLETE_MAN" "$SURFACED_RET"
out=$(drive "$D" "$RUN"); rc=$?
if [ "$rc" -eq 0 ] && [ -d "$D/$RUN" ] \
   && [ ! -d "$D/docs/step-6-done/${DATE}/1501-WAVE-surfaced" ] \
   && ! echo "$out" | grep -q "closeout="; then
  ok "terminal-ONLY: a surfaced run does NOT auto-close (stays in pipeline; no MOVE)"
else
  ko "terminal-only" "rc=$rc still_in_pipeline=$([ -d "$D/$RUN" ] && echo yes || echo no) closeout_fired=$(echo "$out" | grep -q closeout= && echo yes || echo no)"
fi
rm -rf "$D"

# ---- AC-002a: idempotent — a SECOND persist on the already-moved run is a no-op (exit 0, no crash) ----
D=$(mk_repo)
RUN="docs/step-5-pipeline/${DATE}/1502-WAVE-idem"
seed_run "$D" "$RUN" "$COMPLETE_MAN" "$COMPLETE_RET"
drive "$D" "$RUN" >/dev/null; rc1=$?
DONE_RUN="docs/step-6-done/${DATE}/1502-WAVE-idem"
# second persist run, now pointed at the moved folder (re-using its return file)
out2=$(cd "$D" && python3 core/scripts/persist-run-artifacts.py --run-dir "$DONE_RUN" --return-file "$DONE_RUN/_return.json" --no-manifest 2>&1); rc2=$?
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ -d "$D/$DONE_RUN" ]; then
  ok "AC-002: idempotent — a second persist on the already-moved run is a no-op (exit 0, no crash)"
else
  ko "AC-002 idempotent" "rc1=$rc1 rc2=$rc2 still_done=$([ -d "$D/$DONE_RUN" ] && echo yes || echo no) :: $out2"
fi
rm -rf "$D"

# ---- AC-002b: fail-open — a malformed manifest warns + continues; persist completes (exit 0) ----
D=$(mk_repo)
RUN="docs/step-5-pipeline/${DATE}/1503-WAVE-badman"
seed_run "$D" "$RUN" '{not valid json at all' "$COMPLETE_RET"
out=$(drive "$D" "$RUN"); rc=$?
# persist must complete (exit 0) and emit its structured payload despite the broken manifest.
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '"run_status"'; then
  ok "AC-002: malformed manifest → persist warns + completes (fail-open; structured payload emitted)"
else
  ko "AC-002 fail-open" "rc=$rc payload=$(echo "$out" | grep -q run_status && echo yes || echo no)"
fi
rm -rf "$D"

# ---- AC-003: an incomplete ticket HOLDs the move + refluxes to from-<run>/ (scope gate honored) ----
D=$(mk_repo)
RUN="docs/step-5-pipeline/${DATE}/1504-WAVE-gap"
seed_run "$D" "$RUN" "$GAP_MAN" "$GAP_RET"
out=$(drive "$D" "$RUN"); rc=$?
reflux="$D/docs/step-1-ideas/from-1504-WAVE-gap/T-002.md"
if [ -f "$reflux" ] \
   && [ -d "$D/$RUN" ] \
   && [ ! -d "$D/docs/step-6-done/${DATE}/1504-WAVE-gap" ] \
   && echo "$out" | grep -q "closeout=HELD"; then
  ok "AC-003: incomplete ticket → auto path refluxes to from-<run>/ + HOLDs the move (run stays in pipeline)"
else
  ko "AC-003 hold" "reflux=$([ -f "$reflux" ] && echo yes || echo no) in_pipeline=$([ -d "$D/$RUN" ] && echo yes || echo no) held=$(echo "$out" | grep -q closeout=HELD && echo yes || echo no)"
fi
# persist still completed its primary duty (exit 0 + payload) even though the move was HELD.
if [ "$rc" -eq 0 ] && echo "$out" | grep -q '"run_status"'; then ok "AC-003: persist completes (exit 0, payload) despite the HELD move — fail-open"; else ko "AC-003 persist completes" "rc=$rc"; fi
# the complete ticket is NOT refluxed.
if [ ! -f "$D/docs/step-1-ideas/from-1504-WAVE-gap/T-001.md" ]; then ok "AC-003: a complete ticket is NOT refluxed (only the unaccounted atom)"; else ko "AC-003 complete not refluxed" "T-001 should not be refluxed"; fi
rm -rf "$D"

echo ""
echo "============================================"
echo "TOTAL: $((PASS+FAIL)) — PASS: $PASS, FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then echo -e "FAILURES:$FAIL_DETAIL"; exit 1; fi
echo "ALL GREEN"; exit 0
