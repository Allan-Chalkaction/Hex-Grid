#!/usr/bin/env bash
# Synthetic test for launch-manifest.py — the /launch fleet index (T10).
# Asserts init/add/set + the concurrency-aware `next` dispatch decision (RUN/WAIT/DRAINING/COMPLETE).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LM="$HERE/launch-manifest.py"
PY=python3
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
M="$W/fleet.json"

$PY "$LM" init --path "$M" --slug "monday" --concurrency 2 >/dev/null 2>&1
[ -f "$M" ] && ok "init creates fleet manifest" || ko "init" "no file"
$PY -c "import json;m=json.load(open('$M'));assert m['schema']=='fleet-manifest/2';assert m['concurrency']==2" 2>/dev/null \
  && ok "init schema + concurrency" || ko "init schema" "bad"

# add 3 features (labels from spec basenames)
$PY "$LM" add --path "$M" --spec "docs/step-3-specs/demo/waves/x/x.md" >/dev/null 2>&1
$PY "$LM" add --path "$M" --spec "docs/step-3-specs/demo/waves/y/y.md" >/dev/null 2>&1
L3=$($PY "$LM" add --path "$M" --spec "docs/step-3-specs/demo/waves/z/z.md" --label "zed" 2>/dev/null)
[ "$L3" = "zed" ] && ok "add returns explicit label" || ko "add label" "got '$L3'"
$PY -c "import json;m=json.load(open('$M'));assert len(m['features'])==3;assert m['features'][0]['label']=='x';assert m['features'][0]['branch']=='feature/wave-x';assert m['features'][0]['kind']=='orchestrated'" 2>/dev/null \
  && ok "add populates features + default branch + kind" || ko "add shape" "bad"

# duplicate label rejected
$PY "$LM" add --path "$M" --spec "docs/step-3-specs/demo/waves/x/x.md" >/dev/null 2>&1
[ $? -ne 0 ] && ok "add rejects duplicate label" || ko "dup label" "accepted"

# next: all queued, concurrency 2 -> RUN first
N=$($PY "$LM" next --path "$M" 2>/dev/null)
[ "$N" = "RUN:x" ] && ok "next = RUN:x (capacity available)" || ko "next run" "got '$N'"

# mark x,y running -> saturated (2 running, K=2) but z queued -> WAIT:2
$PY "$LM" set --path "$M" --label x --status running >/dev/null 2>&1
$PY "$LM" set --path "$M" --label y --status running >/dev/null 2>&1
N=$($PY "$LM" next --path "$M" 2>/dev/null)
[ "$N" = "WAIT:2" ] && ok "next = WAIT:2 when saturated with a queued item" || ko "next wait" "got '$N'"

# x done -> capacity frees -> RUN:zed
$PY "$LM" set --path "$M" --label x --status done --branch feature/wave-x --sha abc1234 >/dev/null 2>&1
N=$($PY "$LM" next --path "$M" 2>/dev/null)
[ "$N" = "RUN:zed" ] && ok "next = RUN:zed after capacity frees" || ko "next free" "got '$N'"

# y running, zed running, none queued -> DRAINING
$PY "$LM" set --path "$M" --label zed --status running >/dev/null 2>&1
N=$($PY "$LM" next --path "$M" 2>/dev/null)
[ "$N" = "DRAINING" ] && ok "next = DRAINING (none queued, some running)" || ko "next draining" "got '$N'"

# all done -> COMPLETE
$PY "$LM" set --path "$M" --label y --status done >/dev/null 2>&1
$PY "$LM" set --path "$M" --label zed --status done >/dev/null 2>&1
N=$($PY "$LM" next --path "$M" 2>/dev/null)
[ "$N" = "COMPLETE" ] && ok "next = COMPLETE when fleet drained" || ko "next complete" "got '$N'"

# summary counts
S=$($PY "$LM" summary --path "$M" 2>/dev/null)
echo "$S" | $PY -c "import json,sys;d=json.load(sys.stdin);assert d['total']==3;assert d['counts']['done']==3" 2>/dev/null \
  && ok "summary reports status counts" || ko "summary" "got '$S'"

# invalid status rejected
$PY "$LM" set --path "$M" --label x --status bogus >/dev/null 2>&1
[ $? -ne 0 ] && ok "set rejects invalid status" || ko "bad status" "accepted"

# --- multi-track build queue (ADR-053): kind field + kind-aware branches ---
MK="$W/kinds.json"
$PY "$LM" init --path "$MK" --slug "kinds" >/dev/null 2>&1
# AC-1 nimble: kind + branch
$PY "$LM" add --path "$MK" --kind nimble --spec "docs/tasks/foo.md" >/dev/null 2>&1
$PY -c "import json;f=json.load(open('$MK'))['features'][0];assert f['kind']=='nimble';assert f['branch']=='feature/nimble-foo'" 2>/dev/null \
  && ok "add --kind nimble sets kind + feature/nimble- branch (AC-1)" || ko "kind nimble" "bad"
# AC-5 chain + loop branches
$PY "$LM" add --path "$MK" --kind chain --spec "c.md" --label ch >/dev/null 2>&1
$PY "$LM" add --path "$MK" --kind loop  --spec "l.md" --label lp >/dev/null 2>&1
$PY -c "import json;m=json.load(open('$MK'));b={x['label']:x['branch'] for x in m['features']};assert b['ch']=='feature/chain-ch';assert b['lp']=='feature/loop-lp'" 2>/dev/null \
  && ok "add --kind chain/loop set kind-aware branches (AC-5)" || ko "kind chain/loop" "bad"
# AC-3 invalid kind rejected
$PY "$LM" add --path "$MK" --kind bogus --spec "x.md" --label bx >/dev/null 2>&1
[ $? -ne 0 ] && ok "add rejects invalid kind (AC-3)" || ko "bad kind" "accepted"
# AC-4 back-compat: a fleet-manifest/1 file (no kind) reads with kind defaulted to orchestrated
OLD="$W/old.json"
$PY -c "import json;json.dump({'schema':'fleet-manifest/1','slug':'old','created_at':'x','updated_at':'x','concurrency':1,'token_ceiling':None,'features':[{'label':'leg','spec':'w/','status':'queued','branch':'feature/wave-leg','run_dir':None,'sha':None}]},open('$OLD','w'))"
RK=$($PY "$LM" read --path "$OLD" 2>/dev/null | $PY -c "import json,sys;print(json.load(sys.stdin)['features'][0]['kind'])" 2>/dev/null)
[ "$RK" = "orchestrated" ] && ok "v1 manifest (no kind) reads with kind defaulted (AC-4)" || ko "v1 back-compat" "got '$RK'"

# --- /launch add verb behavior (W1LAV; door over cmd_add) ---

# AC-007: duplicate-label LENGTH INVARIANT — a second add of a present label exits non-zero AND
# len(features) is unchanged (reject precedes _atomic_write: cmd_add L86 before L93).
AD="$W/add-dup.json"
$PY "$LM" init --path "$AD" --slug "adddup" >/dev/null 2>&1
$PY "$LM" add --path "$AD" --spec "a.md" --label A >/dev/null 2>&1
BEFORE=$($PY -c "import json;print(len(json.load(open('$AD'))['features']))" 2>/dev/null)
$PY "$LM" add --path "$AD" --spec "a2.md" --label A >/dev/null 2>&1
RC=$?
AFTER=$($PY -c "import json;print(len(json.load(open('$AD'))['features']))" 2>/dev/null)
{ [ "$RC" -ne 0 ] && [ "$BEFORE" = "$AFTER" ] && [ "$AFTER" = "1" ]; } \
  && ok "/launch add duplicate label rejected, len(features) invariant (AC-007)" \
  || ko "add dup length invariant" "rc=$RC before=$BEFORE after=$AFTER"

# AC-008: add-to-COMPLETED RESUMES-AND-FOLDS — drive all features done (next -> COMPLETE), add C,
# then next -> RUN:C (capacity free -> the newly queued feature dispatches and folds into §3 fan-in).
AC="$W/add-completed.json"
$PY "$LM" init --path "$AC" --slug "addcomplete" --concurrency 1 >/dev/null 2>&1
$PY "$LM" add --path "$AC" --spec "a.md" --label A >/dev/null 2>&1
$PY "$LM" add --path "$AC" --spec "b.md" --label B >/dev/null 2>&1
$PY "$LM" set --path "$AC" --label A --status done >/dev/null 2>&1
$PY "$LM" set --path "$AC" --label B --status done >/dev/null 2>&1
N=$($PY "$LM" next --path "$AC" 2>/dev/null)
[ "$N" = "COMPLETE" ] || ko "add-to-completed precondition" "expected COMPLETE got '$N'"
$PY "$LM" add --path "$AC" --spec "c.md" --label C >/dev/null 2>&1
N=$($PY "$LM" next --path "$AC" 2>/dev/null)
[ "$N" = "RUN:C" ] && ok "/launch add to COMPLETE fleet re-queues -> next=RUN:C (AC-008)" \
  || ko "add to completed" "expected RUN:C got '$N'"

# AC-009: NO-AUTO-MERGE GREP GUARD — neither the consumed backend nor the /launch add SKILL subsection
# introduces an auto-merge step. Assert grep finds NO match in either the backend or the add subsection.
SKILL="$HERE/../skills/launch/SKILL.md"
grep -nE 'git merge|git push|gh pr create|--auto' "$LM" >/dev/null 2>&1
GLM=$?
# scope the SKILL grep to the "Add to a live/completed fleet" subsection (T1 writes it).
SUBSEC=$(awk '/^### Add to a live\/completed fleet/{f=1} /^## 2\. Drain the queue/{f=0} f' "$SKILL" 2>/dev/null)
printf '%s' "$SUBSEC" | grep -nE 'git merge|git push|gh pr create|--auto' >/dev/null 2>&1
GSK=$?
{ [ "$GLM" -ne 0 ] && [ "$GSK" -ne 0 ]; } \
  && ok "no auto-merge in backend or /launch add subsection (AC-009)" \
  || ko "auto-merge guard" "backend-grep-rc=$GLM subsection-grep-rc=$GSK (0=match found)"

# AC-008 supporting: add-to-LIVE DRAINS — with a running feature present (capacity permitting), add a
# queued feature and assert the drain decision is honored (next routes the queue, not COMPLETE).
AL="$W/add-live.json"
$PY "$LM" init --path "$AL" --slug "addlive" --concurrency 2 >/dev/null 2>&1
$PY "$LM" add --path "$AL" --spec "r.md" --label R >/dev/null 2>&1
$PY "$LM" set --path "$AL" --label R --status running >/dev/null 2>&1
$PY "$LM" add --path "$AL" --spec "q.md" --label Q >/dev/null 2>&1
N=$($PY "$LM" next --path "$AL" 2>/dev/null)
[ "$N" = "RUN:Q" ] && ok "/launch add to live fleet drains -> next=RUN:Q (capacity free, AC-008)" \
  || ko "add to live drains" "expected RUN:Q got '$N'"

# --- SHR4-B2 (AC-009): runtime hardening — cmd_set upsert + cmd_init fail-loud on empty --slug ---

# AC-009 (a): UPSERT — a `set` on an ABSENT label succeeds (exit 0) and the label is now present, instead of
# the old `_die`. (Resume/crash-recovery `set` ahead of `add` must not strand the drain.)
UP="$W/upsert.json"
$PY "$LM" init --path "$UP" --slug "upsert" >/dev/null 2>&1
$PY "$LM" set --path "$UP" --label ghost --status running >/dev/null 2>&1
URC=$?
UPRESENT=$($PY -c "import json;m=json.load(open('$UP'));print(any(f['label']=='ghost' and f['status']=='running' for f in m['features']))" 2>/dev/null)
{ [ "$URC" -eq 0 ] && [ "$UPRESENT" = "True" ]; } \
  && ok "set upserts an absent label (exit 0, label present) (AC-009)" \
  || ko "set upsert" "rc=$URC present=$UPRESENT"

# AC-009 (a'): the upserted record mirrors cmd_add's shape (default kind=orchestrated + derived branch).
USHAPE=$($PY -c "import json;m=json.load(open('$UP'));f=[x for x in m['features'] if x['label']=='ghost'][0];print(f['kind']=='orchestrated' and f['branch']=='feature/wave-ghost' and f['spec'] is None)" 2>/dev/null)
[ "$USHAPE" = "True" ] && ok "upserted record mirrors add shape (kind=orchestrated, derived branch) (AC-009)" \
  || ko "upsert shape" "got '$USHAPE'"

# AC-009 (a''): an invalid STATUS still dies even on the upsert path (only an unknown LABEL upserts).
$PY "$LM" set --path "$UP" --label phantom --status bogus >/dev/null 2>&1
[ $? -ne 0 ] && ok "set with invalid status still dies on the upsert path (AC-009)" || ko "upsert bad status" "accepted"

# AC-009 (b): cmd_init FAILS LOUD (non-zero) on an empty/whitespace --slug (argparse requires presence; this
# guards the empty-string case that would otherwise write a null-slug manifest).
EI="$W/empty-init.json"
$PY "$LM" init --path "$EI" --slug "" >/dev/null 2>&1
[ $? -ne 0 ] && ok "init exits non-zero on empty --slug (AC-009)" || ko "init empty slug" "accepted empty slug"
[ ! -f "$EI" ] && ok "init writes NO manifest on empty --slug (fail before write) (AC-009)" || ko "init empty slug file" "manifest written"
$PY "$LM" init --path "$EI" --slug "   " >/dev/null 2>&1
[ $? -ne 0 ] && ok "init exits non-zero on whitespace-only --slug (AC-009)" || ko "init whitespace slug" "accepted"

echo ""
echo "launch-manifest: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
