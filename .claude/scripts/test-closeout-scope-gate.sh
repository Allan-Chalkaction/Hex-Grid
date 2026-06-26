#!/usr/bin/env bash
# Synthetic harness for the closeout-run.py OUT-bookend scope gate (ADR-103 W3).
# The regression fixture ADR-103 W3 requires: a run with a deliberately-unbuilt ticket
# CANNOT wrap clean — its atom lands in docs/step-1-ideas/from-<run>/ for triage.
# Each case runs in a throwaway git repo. Exit 0 = all PASS; exit 1 = a FAIL.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLOSEOUT="${REPO_ROOT}/core/scripts/closeout-run.py"
[ -f "$CLOSEOUT" ] || { echo "ERROR: $CLOSEOUT not found" >&2; exit 1; }

PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }

# mk_repo <run-name> <manifest-json>  → echoes the temp repo dir, with a staged run folder.
mk_repo() {
  local name="$1" manifest="$2"
  local d; d=$(mktemp -d)
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t
    mkdir -p "docs/step-5-pipeline/2026-06-14/${name}" docs/step-1-ideas docs/step-6-done
    printf '%s' "$manifest" > "docs/step-5-pipeline/2026-06-14/${name}/manifest.json"
    printf '# run\n' > "docs/step-5-pipeline/2026-06-14/${name}/run-log.md"
    git add -A >/dev/null 2>&1 && git commit -qm init )
  echo "$d"
}

GAP_MANIFEST='{"schema":"thin-manifest/1","slug":"s","track":"orchestrated","tickets":[
  {"key":"T-001","status":"complete","commit_sha":"abc","planned_files":["core/a.py"],"acceptance":["AC-001"]},
  {"key":"T-002","status":"pending","commit_sha":null,"planned_files":["core/b.py"],"acceptance":["AC-002"]}]}'
CLEAN_MANIFEST='{"schema":"thin-manifest/1","slug":"s","track":"orchestrated","tickets":[
  {"key":"T-001","status":"complete","commit_sha":"abc","planned_files":["core/a.py"]},
  {"key":"T-002","status":"complete","commit_sha":"def","planned_files":["core/b.py"]}]}'
NIMBLE_MANIFEST='{"schema":"thin-manifest/1","slug":"s","track":"nimble","steps":[{"phase":"implement","status":"complete"}]}'

run_closeout() { ( cd "$1" && shift && python3 "$CLOSEOUT" "$@" ); }

# ---- T1: an unbuilt ticket HOLDS the move (exit 3), refluxes the atom, leaves the run in pipeline ----
D=$(mk_repo "1500-WAVE-gap" "$GAP_MANIFEST")
out=$(run_closeout "$D" "docs/step-5-pipeline/2026-06-14/1500-WAVE-gap" 2>&1); rc=$?
reflux="$D/docs/step-1-ideas/from-1500-WAVE-gap/T-002.md"
if [ "$rc" -eq 3 ] && [ -f "$reflux" ] \
   && [ -d "$D/docs/step-5-pipeline/2026-06-14/1500-WAVE-gap" ] \
   && [ ! -d "$D/docs/step-6-done/2026-06-14/1500-WAVE-gap" ]; then
  ok "unbuilt ticket → HOLD (exit 3), atom refluxed to from-<run>/, run stays in pipeline"
else
  ko "gap holds" "rc=$rc reflux=$([ -f "$reflux" ] && echo yes || echo no) moved=$([ -d "$D/docs/step-6-done/2026-06-14/1500-WAVE-gap" ] && echo yes || echo no)"
fi
# the complete ticket must NOT be refluxed
if [ ! -f "$D/docs/step-1-ideas/from-1500-WAVE-gap/T-001.md" ]; then ok "a complete ticket is NOT refluxed (only unaccounted atoms)"; else ko "complete not refluxed" "T-001.md should not exist"; fi
# the reflux stub carries the acceptance atom (W1 continuity payoff)
if grep -q "AC-002" "$reflux" 2>/dev/null; then ok "reflux stub carries the ticket's acceptance atoms (continuity)"; else ko "reflux carries atoms" "AC-002 not in stub"; fi
rm -rf "$D"

# ---- T2: all-complete run wraps clean (exit 0), no reflux, folder moved ----
D=$(mk_repo "1501-WAVE-clean" "$CLEAN_MANIFEST")
out=$(run_closeout "$D" "docs/step-5-pipeline/2026-06-14/1501-WAVE-clean" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -d "$D/docs/step-6-done/2026-06-14/1501-WAVE-clean" ] \
   && [ ! -d "$D/docs/step-1-ideas/from-1501-WAVE-clean" ]; then
  ok "all-complete run wraps clean (exit 0, moved to step-6-done, no reflux)"
else
  ko "clean wraps" "rc=$rc moved=$([ -d "$D/docs/step-6-done/2026-06-14/1501-WAVE-clean" ] && echo yes || echo no)"
fi
rm -rf "$D"

# ---- T3: --force-partial moves despite the gap, but STILL refluxes the atom ----
D=$(mk_repo "1502-WAVE-forced" "$GAP_MANIFEST")
out=$(run_closeout "$D" "docs/step-5-pipeline/2026-06-14/1502-WAVE-forced" --force-partial 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -d "$D/docs/step-6-done/2026-06-14/1502-WAVE-forced" ] \
   && [ -f "$D/docs/step-1-ideas/from-1502-WAVE-forced/T-002.md" ]; then
  ok "--force-partial wraps (exit 0) AND still refluxes the unaccounted atom"
else
  ko "force-partial" "rc=$rc moved=$([ -d "$D/docs/step-6-done/2026-06-14/1502-WAVE-forced" ] && echo yes || echo no) reflux=$([ -f "$D/docs/step-1-ideas/from-1502-WAVE-forced/T-002.md" ] && echo yes || echo no)"
fi
rm -rf "$D"

# ---- T4: a nimble run (manifest without tickets[]) skips the gate and wraps clean ----
D=$(mk_repo "1503-NIMBLE-x" "$NIMBLE_MANIFEST")
out=$(run_closeout "$D" "docs/step-5-pipeline/2026-06-14/1503-NIMBLE-x" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -d "$D/docs/step-6-done/2026-06-14/1503-NIMBLE-x" ] && echo "$out" | grep -q "no tickets"; then
  ok "nimble run (no tickets[]) skips the gate and wraps clean"
else
  ko "nimble skip" "rc=$rc out_has_skip=$(echo "$out" | grep -q 'no tickets' && echo yes || echo no)"
fi
rm -rf "$D"

# ---- T5: --skip-scope-check bypasses the gate even with a gap ----
D=$(mk_repo "1504-WAVE-skip" "$GAP_MANIFEST")
out=$(run_closeout "$D" "docs/step-5-pipeline/2026-06-14/1504-WAVE-skip" --skip-scope-check 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -d "$D/docs/step-6-done/2026-06-14/1504-WAVE-skip" ] \
   && [ ! -d "$D/docs/step-1-ideas/from-1504-WAVE-skip" ]; then
  ok "--skip-scope-check bypasses the gate (no reflux, clean move)"
else
  ko "skip-scope" "rc=$rc"
fi
rm -rf "$D"

# ---- T6: reflux is idempotent — a pre-existing triage stub is never overwritten ----
D=$(mk_repo "1505-WAVE-idem" "$GAP_MANIFEST")
mkdir -p "$D/docs/step-1-ideas/from-1505-WAVE-idem"
printf 'OPERATOR EDITED — do not clobber\n' > "$D/docs/step-1-ideas/from-1505-WAVE-idem/T-002.md"
out=$(run_closeout "$D" "docs/step-5-pipeline/2026-06-14/1505-WAVE-idem" 2>&1); rc=$?
if grep -q "OPERATOR EDITED" "$D/docs/step-1-ideas/from-1505-WAVE-idem/T-002.md"; then
  ok "reflux is idempotent (a pre-existing triage stub is preserved, not overwritten)"
else
  ko "reflux idempotent" "operator-edited stub was clobbered"
fi
rm -rf "$D"

# ---- T7: a malformed manifest fails OPEN on read — skips the gate, never bricks the wrap ----
D=$(mk_repo "1506-WAVE-bad" '{not valid json at all')
out=$(run_closeout "$D" "docs/step-5-pipeline/2026-06-14/1506-WAVE-bad" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ -d "$D/docs/step-6-done/2026-06-14/1506-WAVE-bad" ] && echo "$out" | grep -qi "could not read manifest"; then
  ok "malformed manifest → fail-open skip (wrap proceeds; a broken manifest never bricks close-out)"
else
  ko "malformed fail-open" "rc=$rc out_has_warn=$(echo "$out" | grep -qi 'could not read manifest' && echo yes || echo no)"
fi
rm -rf "$D"

# ---- T8: REAL path — manifest built via run-manifest.py set-tickets (full normalization), acceptance
#       atom must survive to the reflux dossier (CR-001: the fixture path must not bypass normalization) ----
RM="${REPO_ROOT}/core/scripts/run-manifest.py"
D=$(mktemp -d)
( cd "$D" && git init -q && git config user.email t@t && git config user.name t
  RUN="docs/step-5-pipeline/2026-06-14/1507-WAVE-realnorm"
  mkdir -p "$RUN" docs/step-1-ideas docs/step-6-done
  printf '# run\n' > "$RUN/run-log.md"
  python3 "$RM" init --run-dir "$RUN" --slug realnorm --track orchestrated --chain explore,implement --out "$RUN/manifest.json" >/dev/null
  cat > /tmp/_t8_tk.json <<'JSON'
[{"key":"T-001","status":"complete","depends_on":[],"planned_files":["core/a.py"],"acceptance":["AC-001"]},
 {"key":"T-002","status":"pending","depends_on":[],"planned_files":["core/b.py"],"acceptance":["AC-099"]}]
JSON
  python3 "$RM" set-tickets "$RUN/manifest.json" --tickets-file /tmp/_t8_tk.json >/dev/null
  git add -A >/dev/null 2>&1 && git commit -qm init )
out=$(run_closeout "$D" "docs/step-5-pipeline/2026-06-14/1507-WAVE-realnorm" 2>&1); rc=$?
stub="$D/docs/step-1-ideas/from-1507-WAVE-realnorm/T-002.md"
if [ "$rc" -eq 3 ] && [ -f "$stub" ] && grep -q "AC-099" "$stub" 2>/dev/null; then
  ok "REAL normalization path (run-manifest.py set-tickets) carries the acceptance atom into the reflux dossier"
else
  ko "real-path continuity" "rc=$rc stub=$([ -f "$stub" ] && echo yes || echo no) has_AC099=$(grep -q AC-099 "$stub" 2>/dev/null && echo yes || echo no)"
fi
rm -f /tmp/_t8_tk.json; rm -rf "$D"

# ---- T9: closeout SURFACES the W4 activation addendum for an unwired script it built (clean wrap) ----
# Guards the wiring: closeout must call activation-check.py (the BUILT_NOT_ACTIVATED anti-pattern at the
# integration level). A complete run that built a script with zero live callers → addendum appears.
ACT="${REPO_ROOT}/core/scripts/activation-check.py"
if [ -f "$ACT" ]; then
  D=$(mktemp -d)
  ( cd "$D" && git init -q && git config user.email t@t && git config user.name t
    RUN="docs/step-5-pipeline/2026-06-14/1508-WAVE-act"
    mkdir -p "$RUN" docs/step-1-ideas docs/step-6-done core/scripts
    cp "$ACT" core/scripts/activation-check.py            # closeout looks for it under the repo root
    printf 'print("nobody calls me")\n' > core/scripts/orphan-cap.py
    printf '# run\n' > "$RUN/run-log.md"
    cat > "$RUN/manifest.json" <<'JSON'
{"schema":"thin-manifest/1","track":"orchestrated","tickets":[
  {"key":"T-001","status":"complete","commit_sha":"abc","planned_files":["core/scripts/orphan-cap.py"]}]}
JSON
    git add -A >/dev/null 2>&1 && git commit -qm init )
  out=$(run_closeout "$D" "docs/step-5-pipeline/2026-06-14/1508-WAVE-act" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && echo "$out" | grep -q "ACTIVATION SURFACE" && echo "$out" | grep -q "orphan-cap.py"; then
    ok "closeout surfaces the W4 activation addendum for an unwired script it built"
  else
    ko "activation wired into closeout" "rc=$rc has_surface=$(echo "$out" | grep -q 'ACTIVATION SURFACE' && echo yes || echo no)"
  fi
  rm -rf "$D"
else
  echo "  SKIP: T9 activation integration (activation-check.py not found)"
fi

echo ""
echo "============================================"
echo "TOTAL: $((PASS+FAIL)) — PASS: $PASS, FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then echo -e "FAILURES:$FAIL_DETAIL"; exit 1; fi
echo "ALL GREEN"; exit 0
