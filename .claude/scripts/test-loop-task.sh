#!/usr/bin/env bash
# Synthetic test harness for the /loop-task scaffold (T6).
# Coverage (no live ralph plugin — exercises the deterministic scaffold core):
#   A. happy path: writes PRD.md/progress.md/prompt.md; default cap = 5; emits a well-formed
#      /ralph-loop command pointing at the run folder.
#   B. explicit cap + custom completion-promise honored.
#   C. --max-iterations 0 warns (UNLIMITED) on stderr but exits 0 and records it.
#   D. invalid cap (negative / non-integer) rejected (exit 2).
#   E. missing required args rejected; --prd-file uses a pre-written PRD; bad --prd-file rejected.
#   F. LOOP_TASK_DEFAULT_MAX_ITER overrides the default.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAFFOLD="$HERE/loop-task-scaffold.sh"
PY=python3
PASS=0; FAIL=0; FAIL_DETAIL=""
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}\n  - $1: $2"; }

SCRATCH=$(mktemp -d)
trap "rm -rf '$SCRATCH'" EXIT

# ===========================================================================
echo "A: happy path — folder shape + default cap (5) + ralph command"
OUT=$("$SCAFFOLD" --run-dir "$SCRATCH/a" --task "get the suite green" 2>/dev/null)
[ -f "$SCRATCH/a/PRD.md" ] && [ -f "$SCRATCH/a/progress.md" ] && [ -f "$SCRATCH/a/prompt.md" ] \
  && ok "writes PRD.md + progress.md + prompt.md" || ko "folder shape" "missing files"
echo "$OUT" | $PY -c "import json,sys;d=json.load(sys.stdin);assert d['max_iterations']==5,d['max_iterations'];assert d['unlimited'] is False;assert d['completion_promise']=='DONE'" 2>/dev/null \
  && ok "default max-iterations = 5, promise = DONE" || ko "default cap" "wrong"
echo "$OUT" | $PY -c "import json,sys;d=json.load(sys.stdin);c=d['ralph_command'];assert c.startswith('/ralph-loop '),c;assert '--max-iterations 5' in c;assert '--completion-promise \"DONE\"' in c;assert '$SCRATCH/a/PRD.md' in c" 2>/dev/null \
  && ok "emits a well-formed /ralph-loop command pointing at the run folder" || ko "ralph command" "malformed"
grep -q "get the suite green" "$SCRATCH/a/PRD.md" && ok "task body captured in PRD" || ko "PRD body" "missing"
# Promise-emission instruction (smoke-test finding): PRD + re-fed prompt must tell the model to
# emit <promise>...</promise> as the FINAL text block, or the Stop-hook misses it and the loop
# runs to the cap instead of exiting.
grep -q "<promise>" "$SCRATCH/a/PRD.md" && grep -qi "last text block\|final" "$SCRATCH/a/PRD.md" \
  && ok "PRD instructs the <promise> terminal-block emission rule" || ko "PRD promise rule" "missing"
echo "$OUT" | $PY -c "import json,sys;d=json.load(sys.stdin);c=d['ralph_command'];assert '<promise>DONE</promise>' in c, c;assert 'nothing after' in c or 'FINAL' in c, c" 2>/dev/null \
  && ok "ralph prompt embeds the <promise> terminal-emission rule" || ko "prompt promise rule" "missing"

# ===========================================================================
echo "B: explicit cap + custom promise honored"
OUT=$("$SCAFFOLD" --run-dir "$SCRATCH/b" --task "fix lint" --max-iterations 12 --completion-promise "LINT CLEAN" 2>/dev/null)
echo "$OUT" | $PY -c "import json,sys;d=json.load(sys.stdin);assert d['max_iterations']==12,d['max_iterations'];assert d['completion_promise']=='LINT CLEAN';assert '--max-iterations 12' in d['ralph_command'];assert '--completion-promise \"LINT CLEAN\"' in d['ralph_command']" 2>/dev/null \
  && ok "explicit cap 12 + custom promise honored" || ko "explicit cap" "wrong"

# ===========================================================================
echo "C: --max-iterations 0 warns (UNLIMITED) but exits 0"
ERR=$("$SCAFFOLD" --run-dir "$SCRATCH/c" --task "x" --max-iterations 0 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 0 ] && echo "$ERR" | grep -qi "UNLIMITED" && ok "0 => exit 0 + UNLIMITED warning on stderr" || ko "unlimited warn" "rc=$RC"
"$SCAFFOLD" --run-dir "$SCRATCH/c2" --task "x" --max-iterations 0 2>/dev/null | $PY -c "import json,sys;d=json.load(sys.stdin);assert d['unlimited'] is True;assert d['max_iterations']==0" 2>/dev/null \
  && ok "summary records unlimited:true" || ko "unlimited flag" "not recorded"

# ===========================================================================
echo "D: invalid cap rejected (exit 2)"
"$SCAFFOLD" --run-dir "$SCRATCH/d1" --task "x" --max-iterations -3 >/dev/null 2>&1; [ $? -eq 2 ] && ok "negative cap rejected" || ko "neg cap" "not rejected"
"$SCAFFOLD" --run-dir "$SCRATCH/d2" --task "x" --max-iterations abc >/dev/null 2>&1; [ $? -eq 2 ] && ok "non-integer cap rejected" || ko "nonint cap" "not rejected"

# ===========================================================================
echo "E: arg validation + --prd-file"
"$SCAFFOLD" --task "no run dir" >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing --run-dir rejected" || ko "missing run-dir" "accepted"
"$SCAFFOLD" --run-dir "$SCRATCH/e1" >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing --task/--prd-file rejected" || ko "missing task" "accepted"
printf '# Custom PRD\n\nspecial-sentinel-xyz\n' > "$SCRATCH/custom-prd.md"
"$SCAFFOLD" --run-dir "$SCRATCH/e2" --prd-file "$SCRATCH/custom-prd.md" >/dev/null 2>&1
grep -q "special-sentinel-xyz" "$SCRATCH/e2/PRD.md" && ok "--prd-file copied into the run folder" || ko "prd-file" "not used"
"$SCAFFOLD" --run-dir "$SCRATCH/e3" --prd-file "$SCRATCH/nope.md" >/dev/null 2>&1; [ $? -eq 2 ] && ok "missing --prd-file rejected" || ko "bad prd-file" "accepted"

# ===========================================================================
echo "H: injection guard — \" or \\ in --completion-promise / --run-dir rejected (CR-001)"
"$SCAFFOLD" --run-dir "$SCRATCH/h1" --task t --completion-promise 'X" --max-iterations 0 "Y' >/dev/null 2>&1
[ $? -eq 2 ] && ok "embedded double-quote in --completion-promise rejected (cap-defeat vector)" || ko "promise quote" "accepted (CR-001 regression)"
"$SCAFFOLD" --run-dir "$SCRATCH/h2" --task t --completion-promise 'X\Y' >/dev/null 2>&1
[ $? -eq 2 ] && ok "embedded backslash in --completion-promise rejected" || ko "promise backslash" "accepted"
"$SCAFFOLD" --run-dir "$SCRATCH/h3\"x" --task t >/dev/null 2>&1
[ $? -eq 2 ] && ok "embedded double-quote in --run-dir rejected" || ko "run-dir quote" "accepted"

echo "F: LOOP_TASK_DEFAULT_MAX_ITER overrides the default"
OUT=$(LOOP_TASK_DEFAULT_MAX_ITER=8 "$SCAFFOLD" --run-dir "$SCRATCH/f" --task "x" 2>/dev/null)
echo "$OUT" | $PY -c "import json,sys;d=json.load(sys.stdin);assert d['max_iterations']==8,d['max_iterations']" 2>/dev/null \
  && ok "env override sets the default cap" || ko "env override" "ignored"

# ===========================================================================
echo "G: scaffold parses (bash -n)"
bash -n "$SCAFFOLD" && ok "loop-task-scaffold.sh parses clean" || ko "scaffold syntax" "bash -n failed"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || { printf "%b\n" "$FAIL_DETAIL"; exit 1; }
