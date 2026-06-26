#!/usr/bin/env bash
# test-claim-id.sh — synthetic test for claim-id.py (ADR-072).
#
# Every sub-test runs in an isolated $TMPDIR; the live repo working tree is NEVER touched.
# The core guarantee — parallel `adr <slug>` claims get DISTINCT numbers — is exercised for
# real with backgrounded subprocesses (& + wait), not simulated.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI="$SCRIPT_DIR/claim-id.py"
PY=python3

PASS=0
FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

# Snapshot live repo working tree state so we can assert it's untouched at the end.
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIVE_BEFORE=$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | sort || true)

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# ---------- adr: basic claim writes the owner marker -----------------------
ADR1="$W/adr-basic"
mkdir -p "$ADR1"
OUT=$($PY "$CI" adr foo-bar --dir "$ADR1" --session-id sess-test 2>/dev/null)
LAST=$(echo "$OUT" | tail -1)
if echo "$LAST" | grep -q '^CLAIM-ADR: number=001 path='; then
  ok "adr: first claim gets number=001"
else
  ko "adr first claim" "last line: $LAST"
fi
P=$(echo "$LAST" | sed 's/.*path=//')
if [ -f "$P" ] && head -1 "$P" | grep -q '^<!-- claimed-by: sess-test at '; then
  ok "adr: stub written with ownership marker"
else
  ko "adr stub" "no marker; file=$P"
fi

# ---------- adr: second claim gets next number -----------------------------
OUT2=$($PY "$CI" adr second --dir "$ADR1" --session-id sess-test 2>/dev/null | tail -1)
if echo "$OUT2" | grep -q '^CLAIM-ADR: number=002 path='; then
  ok "adr: second claim gets number=002"
else
  ko "adr second claim" "last line: $OUT2"
fi

# ---------- adr: pre-existing high number — claim skips past it ------------
ADR2="$W/adr-skip"
mkdir -p "$ADR2"
# Pre-seed an ADR-007-x.md to assert the next claim is ≥008.
touch "$ADR2/ADR-007-existing.md"
OUT=$($PY "$CI" adr next --dir "$ADR2" --session-id sess-test 2>/dev/null | tail -1)
NUM=$(echo "$OUT" | sed -n 's/^CLAIM-ADR: number=\([0-9]*\) path=.*/\1/p')
# Strip leading zeros for arithmetic compare.
NUM_INT=$((10#$NUM))
if [ "$NUM_INT" -ge 8 ]; then
  ok "adr: skips past pre-existing ADR-007 (claimed=$NUM)"
else
  ko "adr skip" "got number=$NUM (want ≥008); last line: $OUT"
fi

# ---------- adr: pre-existing .lock reserves the number --------------------
# A stale or in-flight lock at NNN must reserve NNN — the next claim sees the lock and
# bumps past it (the slug-independent serialization that makes parallel-distinctness work).
ADR_LOCK="$W/adr-lock-only"
mkdir -p "$ADR_LOCK"
touch "$ADR_LOCK/ADR-042.lock"
OUT=$($PY "$CI" adr next-after-lock --dir "$ADR_LOCK" --session-id sess-l 2>/dev/null | tail -1)
NUM=$(echo "$OUT" | sed -n 's/^CLAIM-ADR: number=\([0-9]*\) path=.*/\1/p')
NUM_INT=$((10#$NUM))
if [ "$NUM_INT" -ge 43 ]; then
  ok "adr: pre-existing .lock at 042 reserves the number (next claim=$NUM ≥ 043)"
else
  ko "adr lock-only skip" "got number=$NUM (want ≥043); last line: $OUT"
fi

# ---------- adr: PARALLEL CLAIMS GET DISTINCT NUMBERS ----------------------
# This is the load-bearing test: the entire point of ADR-072 / claim-id.py is that
# two concurrent sessions claiming ADRs against the same dir must get DIFFERENT
# numbers and neither's content is clobbered. We launch N parallel subprocesses
# against an empty dir and assert (a) N unique numbers, (b) N files on disk, (c)
# each file's first line carries its own claimer's marker.
ADR_PAR="$W/adr-parallel"
mkdir -p "$ADR_PAR"
OUTDIR="$W/parallel-out"
mkdir -p "$OUTDIR"
N=8
for i in $(seq 1 $N); do
  ( $PY "$CI" adr "slug-$i" --dir "$ADR_PAR" --session-id "sess-$i" > "$OUTDIR/out-$i.txt" 2>&1 ) &
done
wait

# Collect numbers from each subprocess's last-line CLAIM-ADR.
NUMS=""
ALL_OK=1
for i in $(seq 1 $N); do
  L=$(tail -1 "$OUTDIR/out-$i.txt")
  N_I=$(echo "$L" | sed -n 's/^CLAIM-ADR: number=\([0-9]*\) path=.*/\1/p')
  if [ -z "$N_I" ]; then
    ALL_OK=0
    break
  fi
  NUMS="$NUMS $N_I"
done
if [ "$ALL_OK" = "1" ]; then
  ok "adr-parallel: all $N subprocesses returned CLAIM-ADR lines"
else
  ko "adr-parallel run" "one or more subprocesses failed; check $OUTDIR/"
fi

# Distinctness: the sorted-unique count of numbers MUST equal N.
UNIQ=$(echo "$NUMS" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l | tr -d ' ')
TOTAL=$(echo "$NUMS" | tr ' ' '\n' | grep -v '^$' | wc -l | tr -d ' ')
if [ "$UNIQ" = "$N" ] && [ "$TOTAL" = "$N" ]; then
  ok "adr-parallel: $N concurrent claims got $UNIQ DISTINCT numbers (the ADR-072 guarantee)"
else
  ko "adr-parallel distinctness" "want $N unique numbers; got $UNIQ unique / $TOTAL total. NUMS:$NUMS"
fi

# On-disk: N .md files must exist (and the same N .lock files alongside — the lock is
# the slug-independent number-reservation sentinel that makes parallel-distinctness work).
MD_ON_DISK=$(ls "$ADR_PAR" | grep -c '^ADR-.*\.md$' || true)
LOCKS_ON_DISK=$(ls "$ADR_PAR" | grep -c '^ADR-.*\.lock$' || true)
if [ "$MD_ON_DISK" = "$N" ] && [ "$LOCKS_ON_DISK" = "$N" ]; then
  ok "adr-parallel: $N distinct .md files + $N .lock sentinels written (no clobbering)"
else
  ko "adr-parallel files" "want $N .md + $N .lock; got $MD_ON_DISK .md / $LOCKS_ON_DISK .lock"
fi

# Each file's first line carries its own claimer's marker — proves no file was overwritten.
NO_CLOBBER=1
for f in "$ADR_PAR"/ADR-*.md; do
  if ! head -1 "$f" | grep -qE '^<!-- claimed-by: sess-[0-9]+ at '; then
    NO_CLOBBER=0
    break
  fi
done
if [ "$NO_CLOBBER" = "1" ]; then
  ok "adr-parallel: every file's first-line marker proves its own claim won (no silent overwrite)"
else
  ko "adr-parallel markers" "at least one file missing an expected sess-N ownership marker"
fi

# ---------- run: claim a run folder ----------------------------------------
RUN1="$W/run-basic"
mkdir -p "$RUN1"
OUT=$($PY "$CI" run NIMBLE my-feature --dir "$RUN1" --date 2026-06-08 --time 1530 --session-id sess-r 2>/dev/null | tail -1)
RP=$(echo "$OUT" | sed 's/^CLAIM-RUN: path=//')
EXPECT="$RUN1/2026-06-08/1530-NIMBLE-my-feature"
if [ "$RP" = "$EXPECT" ] && [ -d "$RP" ] && [ -f "$RP/.owner" ]; then
  ok "run: basic claim creates folder + .owner sentinel"
else
  ko "run basic" "got '$RP' (expected '$EXPECT'); dir exists=$( [ -d "$RP" ] && echo y || echo n); owner exists=$( [ -f "$RP/.owner" ] && echo y || echo n)"
fi

# ---------- run: collision -> suffixed -2 ----------------------------------
OUT2=$($PY "$CI" run NIMBLE my-feature --dir "$RUN1" --date 2026-06-08 --time 1530 --session-id sess-r 2>/dev/null | tail -1)
RP2=$(echo "$OUT2" | sed 's/^CLAIM-RUN: path=//')
EXPECT2="$RUN1/2026-06-08/1530-NIMBLE-my-feature-2"
if [ "$RP2" = "$EXPECT2" ] && [ -d "$RP2" ]; then
  ok "run: collision claim returns -2 suffix"
else
  ko "run collision" "got '$RP2' (expected '$EXPECT2')"
fi

# ---------- run: parallel run claims also distinct -------------------------
RUN_PAR="$W/run-parallel"
mkdir -p "$RUN_PAR"
ROUT="$W/run-parallel-out"
mkdir -p "$ROUT"
NR=5
for i in $(seq 1 $NR); do
  ( $PY "$CI" run CHAIN slug-x --dir "$RUN_PAR" --date 2026-06-08 --time 0900 --session-id "sess-$i" > "$ROUT/out-$i.txt" 2>&1 ) &
done
wait
RPATHS=""
for i in $(seq 1 $NR); do
  RPATHS="$RPATHS $(tail -1 "$ROUT/out-$i.txt" | sed 's/^CLAIM-RUN: path=//')"
done
UNIQ_R=$(echo "$RPATHS" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l | tr -d ' ')
if [ "$UNIQ_R" = "$NR" ]; then
  ok "run-parallel: $NR concurrent run claims got $UNIQ_R DISTINCT paths"
else
  ko "run-parallel distinctness" "got $UNIQ_R unique out of $NR; RPATHS:$RPATHS"
fi

# ---------- path: success then lost-race -----------------------------------
PATHD="$W/path-basic"
mkdir -p "$PATHD"
T="$PATHD/claim.txt"
OUT=$($PY "$CI" path "$T" --session-id sess-p 2>/dev/null | tail -1)
if echo "$OUT" | grep -q "^CLAIM-PATH: path=" && [ -f "$T" ]; then
  ok "path: success writes file + owner marker"
else
  ko "path success" "last line: $OUT; exists=$( [ -f "$T" ] && echo y || echo n)"
fi

# Re-claim the same path: must lose, must NOT clobber.
ORIG_CONTENT=$(cat "$T")
OUT_FAIL=$($PY "$CI" path "$T" --session-id sess-p2 2>/dev/null | tail -1)
EXIT_CODE=$?
NEW_CONTENT=$(cat "$T")
if echo "$OUT_FAIL" | grep -q "^CLAIM-PATH: FAILED path=" && [ "$ORIG_CONTENT" = "$NEW_CONTENT" ]; then
  ok "path: lost-race exits non-zero, original file untouched"
else
  ko "path lost-race" "last line: $OUT_FAIL; clobbered=$( [ "$ORIG_CONTENT" = "$NEW_CONTENT" ] && echo no || echo YES)"
fi

# ---------- slug validation: REJECT path-traversal -------------------------
BAD_DIR="$W/bad-slug"
mkdir -p "$BAD_DIR"
SENTINEL="$W/SENTINEL"  # a place a successful traversal could land — must NOT exist after
# slug "../../SENTINEL"
$PY "$CI" adr "../../SENTINEL" --dir "$BAD_DIR" --session-id sess-b >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$SENTINEL" ] && [ -z "$(ls "$BAD_DIR")" ]; then
  ok "adr: rejects slug with '../' traversal (no file created)"
else
  ko "adr traversal reject" "exit=$RC OR sentinel created OR dir not empty"
fi

# slug with path separator
$PY "$CI" adr "foo/bar" --dir "$BAD_DIR" --session-id sess-b >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ -z "$(ls "$BAD_DIR")" ]; then
  ok "adr: rejects slug with '/' separator"
else
  ko "adr sep reject" "exit=$RC OR file created"
fi

# slug with leading hyphen
$PY "$CI" adr "-evil" --dir "$BAD_DIR" --session-id sess-b >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ -z "$(ls "$BAD_DIR")" ]; then
  ok "adr: rejects slug with leading '-'"
else
  ko "adr leading-dash reject" "exit=$RC OR file created"
fi

# empty slug
$PY "$CI" adr "" --dir "$BAD_DIR" --session-id sess-b >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ -z "$(ls "$BAD_DIR")" ]; then
  ok "adr: rejects empty slug"
else
  ko "adr empty reject" "exit=$RC OR file created"
fi

# slug with uppercase (must be kebab-lowercase per SLUG_RE)
$PY "$CI" adr "FooBar" --dir "$BAD_DIR" --session-id sess-b >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ -z "$(ls "$BAD_DIR")" ]; then
  ok "adr: rejects non-kebab slug (uppercase)"
else
  ko "adr case reject" "exit=$RC OR file created"
fi

# ---------- kind validation: REJECT bad kind -------------------------------
BAD_RUN="$W/bad-run"
mkdir -p "$BAD_RUN"
$PY "$CI" run "lower" myslug --dir "$BAD_RUN" --date 2026-06-08 --time 0900 >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  ok "run: rejects lowercase kind"
else
  ko "run kind reject" "exit=$RC for kind=lower"
fi

$PY "$CI" run "../evil" myslug --dir "$BAD_RUN" --date 2026-06-08 --time 0900 >/dev/null 2>&1
RC=$?
SENTINEL2="$W/EVIL-RUN"
if [ "$RC" -ne 0 ] && [ ! -d "$SENTINEL2" ]; then
  ok "run: rejects kind with traversal"
else
  ko "run kind traversal" "exit=$RC (expected non-zero); escape=$( [ -d "$SENTINEL2" ] && echo YES || echo no)"
fi

# ---------- gate remediation: SA-001 / SA-002 / CR-001 --------------------

# SA-002: a poisoned --date must be rejected (can't traverse out of the pipeline parent).
DATE_RUN="$W/date-run"; mkdir -p "$DATE_RUN"
$PY "$CI" run NIMBLE myslug --dir "$DATE_RUN" --date '../../../escaped-date' --time 0900 >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ ! -d "$W/escaped-date" ]; then
  ok "run: rejects --date path traversal (SA-002)"
else
  ko "run date traversal" "exit=$RC; escape=$( [ -d "$W/escaped-date" ] && echo YES || echo no)"
fi
# and a bad --time
$PY "$CI" run NIMBLE myslug --dir "$DATE_RUN" --date 2026-06-08 --time 'bad' >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "run: rejects malformed --time (SA-002)" || ko "run time format" "accepted bad --time"

# CR-001: the path subcommand must reject a `..` segment mid-string (not just the leaf).
PD="$W/pd"; mkdir -p "$PD"
$PY "$CI" path "$PD/../escaped-path.txt" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$W/escaped-path.txt" ]; then
  ok "path: rejects mid-string '..' traversal (CR-001)"
else
  ko "path .. traversal" "exit=$RC; escape=$( [ -f "$W/escaped-path.txt" ] && echo YES || echo no)"
fi

# SA-001: a session id containing a newline must NOT forge a second marker line.
INJ_DEC="$W/inj-dec"; mkdir -p "$INJ_DEC"
$PY "$CI" adr footest --dir "$INJ_DEC" --session-id "$(printf 'real\nclaimed-by: forged')" >/dev/null 2>&1
STUB=$(ls "$INJ_DEC"/ADR-*-footest.md 2>/dev/null | head -1)
# The marker must be a single line; a second standalone 'claimed-by:' line = injection.
# grep -c already prints 0 on no-match (and exits 1); `|| true` swallows the exit
# without appending a second line.
INJ_LINES=$(grep -c '^claimed-by:' "$STUB" 2>/dev/null || true)
FIRST_LINE_OK=$(head -1 "$STUB" 2>/dev/null | grep -c 'claimed-by: real claimed-by: forged' || true)
if [ "$INJ_LINES" = "0" ] && [ "$FIRST_LINE_OK" = "1" ]; then
  ok "adr: session-id newline can't forge a second marker line (SA-001)"
else
  ko "adr marker injection" "standalone claimed-by lines=$INJ_LINES; collapsed-first-line=$FIRST_LINE_OK"
fi

# ---------- live repo untouched -------------------------------------------
LIVE_AFTER=$(cd "$REPO_ROOT" && git status --porcelain 2>/dev/null | sort || true)
if [ "$LIVE_BEFORE" = "$LIVE_AFTER" ]; then
  ok "live repo working tree untouched by the harness"
else
  ko "live repo state" "git status changed during test run"
fi

echo ""
echo "test-claim-id: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
