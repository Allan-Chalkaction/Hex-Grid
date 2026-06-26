#!/usr/bin/env bash
# Synthetic test for queue-order.py — the DETERMINISTIC add-time orderer (ADR-122, AWQ-T2; F9).
# Asserts the five placement cases + overlap derivation produce a correct, deterministic `seq`
# (or a conflict flag) — never a probabilistic call. Also exercises the add -> order -> write path
# end-to-end (AWQ-T3 / AC-007 wire-to-consumer).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
QO="$HERE/queue-order.py"
PY=python3
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
PENDING="$W/pending"
mkdir -p "$PENDING"

# Helper: write a pending entry in the ENTRY-AS-FOLDER shape (ADR-124) the way the /queue add door will:
#   pending/<label>/ contains the moved source artifact (<label>.md) + sidecar.json {label,verb,seq,...,target}.
# args: label seq [after] [planned_files_csv]
write_entry() {
  local label="$1" seq="$2" after="${3:-}" pf="${4:-}"
  mkdir -p "$PENDING/$label"
  : > "$PENDING/$label/$label.md"            # the moved-in source artifact (the build target)
  $PY - "$PENDING/$label/sidecar.json" "$label" "$seq" "$after" "$pf" <<'PYEOF'
import json, sys
path, label, seq, after, pf = sys.argv[1:6]
side = {"verb": "orchestrated", "label": label, "seq": float(seq) if "." in seq else int(seq), "target": "."}
if after:
    side["after"] = after
if pf:
    side["planned_files"] = pf.split(",")
json.dump(side, open(path, "w"))
PYEOF
}

# compute_seq: run `compute`, return the seq (stdout JSON .seq). Captures exit code in $RC_COMPUTE.
RC_COMPUTE=0
compute_seq() {
  local out
  out=$($PY "$QO" compute --pending "$PENDING" "$@" 2>/dev/null); RC_COMPUTE=$?
  printf '%s' "$out" | $PY -c "import json,sys;print(json.load(sys.stdin)['seq'])" 2>/dev/null
}
compute_raw() { $PY "$QO" compute --pending "$PENDING" "$@" 2>/dev/null; }

# --- 1. Empty queue -> first seq (deterministic) ---
S=$(compute_seq)
[ "$S" = "100" ] && ok "empty queue -> first seq=100 (deterministic)" || ko "empty" "got '$S'"

# --- 2. Append (default, FIFO by seq) -> after current max ---
write_entry A 100
write_entry B 200
S=$(compute_seq)
[ "$S" = "300" ] && ok "append -> seq after max (300)" || ko "append" "got '$S'"

# --- 3. `after X` mid-tape insert -> POSITION insert (between X and successor), NOT end-of-tape (F4) ---
# Tape: A=100, B=200, C=300. Add `after A` -> must land between A(100) and B(200) = 150, NOT at 400.
write_entry C 300
S=$(compute_seq --after A)
[ "$S" = "150.0" ] && ok "after A mid-tape -> seq 150.0 (position insert, not tail; F4)" || ko "after X mid-tape" "got '$S' (expected 150.0, not 400)"
# after the LAST entry -> append past it
S=$(compute_seq --after C)
[ "$S" = "400" ] && ok "after last entry -> seq 400 (append past tail)" || ko "after last" "got '$S'"

# --- 4. --top -> jump to front (below current min) ---
S=$(compute_seq --top)
[ "$S" = "0" ] && ok "--top -> seq below min (0)" || ko "--top" "got '$S'"

# --- 5. Forward-referenced `after X` (X absent) -> deterministic: provisional tail + conflict flag, no guess ---
RAW=$(compute_raw --after ZZZ)
RC=$?
echo "$RAW" | $PY -c "import json,sys;d=json.load(sys.stdin);assert d['seq']==400;assert d['conflict'] and 'forward-reference' in d['conflict']" 2>/dev/null
FR=$?
{ [ "$RC" -eq 3 ] && [ "$FR" -eq 0 ]; } \
  && ok "forward-ref after-absent-X -> provisional tail + conflict flag, exit 3 (never guess)" \
  || ko "forward-ref" "rc=$RC flag-check=$FR raw=$RAW"

# --- 6. Overlapping planned_files, UNDECLARED -> deterministic conflict flag (not a probabilistic call) ---
PEN2="$W/pending2"; mkdir -p "$PEN2/X"
: > "$PEN2/X/X.md"
$PY -c "import json;json.dump({'verb':'orchestrated','label':'X','seq':100,'target':'.','planned_files':['src/a.ts','src/b.ts']},open('$PEN2/X/sidecar.json','w'))"
RAW=$($PY "$QO" compute --pending "$PEN2" --planned-files "src/a.ts,src/c.ts" 2>/dev/null)
RC=$?
echo "$RAW" | $PY -c "import json,sys;d=json.load(sys.stdin);assert d['conflict'] and 'overlap' in d['conflict']" 2>/dev/null
OV=$?
{ [ "$RC" -eq 3 ] && [ "$OV" -eq 0 ]; } \
  && ok "undeclared planned_files overlap -> deterministic conflict flag, exit 3 (never guess)" \
  || ko "overlap conflict" "rc=$RC flag-check=$OV raw=$RAW"

# --- 6b. Overlapping planned_files WITH explicit `after` -> operator declared -> NO conflict, ordered ---
RAW=$($PY "$QO" compute --pending "$PEN2" --after X --planned-files "src/a.ts,src/c.ts" 2>/dev/null)
RC=$?
echo "$RAW" | $PY -c "import json,sys;d=json.load(sys.stdin);assert d['conflict'] is None;assert d['seq']==200" 2>/dev/null
OD=$?
{ [ "$RC" -eq 0 ] && [ "$OD" -eq 0 ]; } \
  && ok "overlap + explicit after X -> ordered deterministically, no flag (operator declared)" \
  || ko "overlap declared" "rc=$RC check=$OD raw=$RAW"

# --- 7. Determinism: identical inputs -> identical seq (no randomness) ---
S1=$(compute_seq --after A); S2=$(compute_seq --after A)
[ "$S1" = "$S2" ] && [ "$S1" = "150.0" ] && ok "deterministic: identical inputs -> identical seq" || ko "determinism" "$S1 vs $S2"

# --- 8. END-TO-END add -> order -> write (AC-007 wire-to-consumer path the /queue add door drives) ---
# Simulate the exact add flow: read live pending/, CALL queue-order.py to compute seq, then write the entry.
PEN3="$W/pending3"; mkdir -p "$PEN3"
add_entry() {  # label [after|--top flags...]
  local label="$1"; shift
  local seq
  seq=$($PY "$QO" compute --pending "$PEN3" "$@" 2>/dev/null | $PY -c "import json,sys;print(json.load(sys.stdin)['seq'])")
  mkdir -p "$PEN3/$label"
  : > "$PEN3/$label/$label.md"
  $PY -c "import json,sys;json.dump({'verb':'orchestrated','label':'$label','seq':$seq,'target':'.'},open('$PEN3/$label/sidecar.json','w'))"
}
add_entry first
add_entry second
add_entry zero --top
# Resolve final order via the orderer itself.
ORDER=$($PY "$QO" order --pending "$PEN3" 2>/dev/null | $PY -c "import json,sys;print(','.join(e['label'] for e in json.load(sys.stdin)))")
[ "$ORDER" = "zero,first,second" ] && ok "end-to-end add->order->write: order resolves zero,first,second (AC-007)" || ko "e2e add path" "got '$ORDER'"

# --- 9. CR-001: tight-gap `after X` chain must FLAG (exit 3) before the midpoint underflows into a collision ---
# Seed an adjacent pair A=100,B=101 (gap of 1). A long chain of `after A` inserts into that SAME gap will
# bisect 100<->101 (100.5, 100.25, ...) until the float midpoint underflows to == A's seq. The orderer MUST
# emit a deterministic conflict (exit 3) advising compaction rather than silently return a seq <= the anchor.
PEN4="$W/pending4"; mkdir -p "$PEN4/A" "$PEN4/B"
: > "$PEN4/A/A.md"; : > "$PEN4/B/B.md"
$PY -c "import json;json.dump({'verb':'orchestrated','label':'A','seq':100,'target':'.'},open('$PEN4/A/sidecar.json','w'))"
$PY -c "import json;json.dump({'verb':'orchestrated','label':'B','seq':101,'target':'.'},open('$PEN4/B/sidecar.json','w'))"
TG_FLAGGED=0; TG_BAD=0
i=0
while [ "$i" -lt 70 ]; do
  RAW=$($PY "$QO" compute --pending "$PEN4" --after A 2>/dev/null); RC=$?
  SEQ=$(printf '%s' "$RAW" | $PY -c "import json,sys;print(json.load(sys.stdin)['seq'])" 2>/dev/null)
  if [ "$RC" -eq 3 ]; then
    # Conflict raised: assert it advises compaction/renumber and never returns a seq <= the anchor (100).
    echo "$RAW" | $PY -c "import json,sys;d=json.load(sys.stdin);assert d['conflict'] and ('compaction' in d['conflict'] or 'renumber' in d['conflict'] or 'gap exhausted' in d['conflict']);assert d['seq']<=100" 2>/dev/null && TG_FLAGGED=1
    break
  fi
  # Before a flag fires, every returned seq MUST be strictly inside the (100,101) gap — never <= anchor.
  $PY -c "import sys;s=float('$SEQ');sys.exit(0 if 100 < s < 101 else 1)" 2>/dev/null || TG_BAD=1
  # Persist this insert into the SAME gap so the next `after A` bisects the now-tighter sub-gap.
  mkdir -p "$PEN4/T$i"
  : > "$PEN4/T$i/T$i.md"
  $PY -c "import json;json.dump({'verb':'orchestrated','label':'T$i','seq':$SEQ,'target':'.'},open('$PEN4/T$i/sidecar.json','w'))"
  i=$((i+1))
done
{ [ "$TG_FLAGGED" -eq 1 ] && [ "$TG_BAD" -eq 0 ]; } \
  && ok "CR-001: tight-gap after-X chain FLAGS (exit 3, advises compaction) — never collides with anchor" \
  || ko "CR-001 tight-gap" "flagged=$TG_FLAGGED bad-intermediate=$TG_BAD (a seq landed <=100 or outside the gap)"

# --- 10. CR-002: kind-prefixed e2e — `after <KIND-LABEL>` resolves a PRESENT anchor (real position insert) ---
# The producer writes label="${KIND}-${LABEL}"; `after X` takes that exact token. Adding `after orchestrated-first`
# must RESOLVE to a position insert (no conflict), NOT be misread as an absent forward-reference.
PEN5="$W/pending5"; mkdir -p "$PEN5"
add_kind() {  # bare-label [after-token]
  local bare="$1"; shift
  local kind="orchestrated" lbl
  lbl="orchestrated-$bare"
  local seq rc
  RES=$($PY "$QO" compute --pending "$PEN5" "$@" 2>/dev/null); rc=$?
  seq=$(printf '%s' "$RES" | $PY -c "import json,sys;print(json.load(sys.stdin)['seq'])" 2>/dev/null)
  RC_ADDKIND=$rc
  if [ "$rc" -ne 0 ]; then return; fi
  mkdir -p "$PEN5/$lbl"
  : > "$PEN5/$lbl/$lbl.md"
  $PY -c "import json;json.dump({'label':'$lbl','verb':'$kind','seq':$seq,'target':'.'},open('$PEN5/$lbl/sidecar.json','w'))"
}
add_kind first        # -> orchestrated-first, seq 100
add_kind second       # -> orchestrated-second, seq 200
add_kind third --after orchestrated-first   # must resolve PRESENT anchor -> seq 150.0, exit 0
{ [ "$RC_ADDKIND" -eq 0 ] && [ "$(printf '%s' "$RES" | $PY -c "import json,sys;print(json.load(sys.stdin)['seq'])")" = "150.0" ]; } \
  && ok "CR-002: after <KIND-LABEL> resolves PRESENT anchor -> position insert (seq 150.0), not forward-ref" \
  || ko "CR-002 anchor resolution" "rc=$RC_ADDKIND res=$RES (expected exit 0, seq 150.0)"

# --- 11. CR-004: forward-ref `after X` (X ABSENT) + real overlap with a PRESENT entry -> overlap still surfaced ---
# When `after` names an absent anchor, the declaration is UNHONORABLE, so an overlap with a present entry must
# NOT be masked. Tape has present P (planned_files src/a.ts); add `after ABSENT` overlapping src/a.ts -> flag.
PEN6="$W/pending6"; mkdir -p "$PEN6/P"
: > "$PEN6/P/P.md"
$PY -c "import json;json.dump({'verb':'orchestrated','label':'P','seq':100,'target':'.','planned_files':['src/a.ts','src/b.ts']},open('$PEN6/P/sidecar.json','w'))"
RAW=$($PY "$QO" compute --pending "$PEN6" --after ABSENT --planned-files "src/a.ts,src/c.ts" 2>/dev/null); RC=$?
echo "$RAW" | $PY -c "import json,sys;d=json.load(sys.stdin);assert d['conflict'] and 'overlap' in d['conflict']" 2>/dev/null
FRO=$?
{ [ "$RC" -eq 3 ] && [ "$FRO" -eq 0 ]; } \
  && ok "CR-004: forward-ref (absent anchor) + present overlap -> overlap flag surfaced, not masked (exit 3)" \
  || ko "CR-004 forward-ref overlap" "rc=$RC overlap-check=$FRO raw=$RAW"

# --- 11b. CR-004 regression guard: PRESENT-anchor `after X` + overlap -> still suppressed (operator owns it) ---
# Honorable declaration must keep the existing suppression: present anchor X with overlap -> NO flag, ordered.
RAW=$($PY "$QO" compute --pending "$PEN6" --after P --planned-files "src/a.ts,src/c.ts" 2>/dev/null); RC=$?
echo "$RAW" | $PY -c "import json,sys;d=json.load(sys.stdin);assert d['conflict'] is None" 2>/dev/null
PAO=$?
{ [ "$RC" -eq 0 ] && [ "$PAO" -eq 0 ]; } \
  && ok "CR-004 guard: present-anchor after X + overlap -> suppressed (honorable declaration, operator owns)" \
  || ko "CR-004 present-anchor suppression" "rc=$RC check=$PAO raw=$RAW"

# --- 12. AWQ-T6 (AC-017): `dependents` subcommand — a failed item's DECLARED dependents are skipped,
#         independents proceed. This is the wire-to-consumer proof the queue-chew arbiter relies on:
#         the daemon CALLS `queue-order.py dependents --label X` to learn the skip-set when X fails/dirties
#         the base. Construct a tape with a failing item X, a Y declaring `after X` (must be a dependent →
#         skipped), and an independent Z (must NOT be a dependent → proceeds).
PEN7="$W/pending7"; mkdir -p "$PEN7"
write_entry7() {  # label seq [after] [planned_files_csv]   (PEN7-scoped variant of write_entry)
  local label="$1" seq="$2" after="${3:-}" pf="${4:-}"
  mkdir -p "$PEN7/$label"
  : > "$PEN7/$label/$label.md"
  $PY - "$PEN7/$label/sidecar.json" "$label" "$seq" "$after" "$pf" <<'PYEOF'
import json, sys
path, label, seq, after, pf = sys.argv[1:6]
side = {"verb": "orchestrated", "label": label, "seq": float(seq) if "." in seq else int(seq), "target": "."}
if after:
    side["after"] = after
if pf:
    side["planned_files"] = pf.split(",")
json.dump(side, open(path, "w"))
PYEOF
}
write_entry7 X 100                        # the item that fails / dirties the base
write_entry7 Y 200 X                       # declares `after X` -> X's DECLARED dependent -> must be SKIPPED
write_entry7 Z 300                         # independent -> NOT a dependent -> must PROCEED
DEP=$($PY "$QO" dependents --pending "$PEN7" --label X 2>/dev/null); RC=$?
echo "$DEP" | $PY -c "
import json,sys
d=json.load(sys.stdin)
assert d['label']=='X', d
assert d['after_deps']==['Y'], d          # Y declared after X -> declared dependent
assert 'Y' in d['all_deps'], d            # Y is in the skip-set
assert 'Z' not in d['all_deps'], d        # Z independent -> NOT in the skip-set -> proceeds
assert d['overlap_deps']==[], d           # no planned_files overlap declared here
" 2>/dev/null
T6=$?
{ [ "$RC" -eq 0 ] && [ "$T6" -eq 0 ]; } \
  && ok "AC-017: failed item's DECLARED dependent (after X) is in skip-set; independent proceeds" \
  || ko "AC-017 dependents (after edge)" "rc=$RC check=$T6 out=$DEP"

# --- 12b. AWQ-T6 (AC-017): the OTHER edge kind — a `planned_files`-overlap dependent is ALSO surfaced.
#         Reading only `after X` would let a structurally-dependent-but-undeclared item stack on a broken
#         base (the wave's #2 watch-item). `dependents` must union the derived overlap edge too.
PEN8="$W/pending8"; mkdir -p "$PEN8"
write_entry8() {  # label seq [after] [planned_files_csv]   (PEN8-scoped variant)
  local label="$1" seq="$2" after="${3:-}" pf="${4:-}"
  mkdir -p "$PEN8/$label"
  : > "$PEN8/$label/$label.md"
  $PY - "$PEN8/$label/sidecar.json" "$label" "$seq" "$after" "$pf" <<'PYEOF'
import json, sys
path, label, seq, after, pf = sys.argv[1:6]
side = {"verb": "orchestrated", "label": label, "seq": float(seq) if "." in seq else int(seq), "target": "."}
if after:
    side["after"] = after
if pf:
    side["planned_files"] = pf.split(",")
json.dump(side, open(path, "w"))
PYEOF
}
write_entry8 X 100 "" "src/a.ts,src/b.ts"         # X touches a.ts,b.ts
write_entry8 W 200 "" "src/b.ts,src/c.ts"          # overlaps X on b.ts -> structural dependent (undeclared)
write_entry8 Z 300 "" "src/z.ts"                    # disjoint -> independent
DEP=$($PY "$QO" dependents --pending "$PEN8" --label X 2>/dev/null); RC=$?
echo "$DEP" | $PY -c "
import json,sys
d=json.load(sys.stdin)
assert d['overlap_deps']==['W'], d        # W overlaps X's planned_files -> derived edge surfaced
assert 'W' in d['all_deps'], d
assert 'Z' not in d['all_deps'], d        # Z disjoint -> independent
assert d['after_deps']==[], d             # no after-edge declared in this tape
" 2>/dev/null
T6B=$?
{ [ "$RC" -eq 0 ] && [ "$T6B" -eq 0 ]; } \
  && ok "AC-017: planned_files-overlap dependent surfaced too (both edge kinds unioned, not just after X)" \
  || ko "AC-017 dependents (overlap edge)" "rc=$RC check=$T6B out=$DEP"

echo ""
echo "queue-order: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
