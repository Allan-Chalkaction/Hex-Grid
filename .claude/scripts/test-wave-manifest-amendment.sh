#!/usr/bin/env bash
# V2-W2-T01 synthetic acceptance tests for the amendment-and-propagation
# helpers in core/scripts/wave-manifest.py.
#
# Coverage:
#   detect_amendment:
#     - returns None when actual == planned
#     - returns descriptor when files added / removed / mixed
#     - raises on unknown ticket_key
#   scan_downstream_impact:
#     - depends_on edge → included
#     - planned_files intersection → included
#     - status 'complete' → excluded
#     - status 'blocked' → excluded
#     - source ticket → excluded from own scan
#   apply_amendment_source:
#     - unions planned_files
#     - appends amendment_history with from_ticket=source_key (self-marker)
#     - status in-progress → amending
#     - idempotent on same delta_summary
#   apply_amendment_downstream:
#     - appends to prompt.md under correct heading
#     - status pending → pending-amendment-applied
#     - appends amendment_history with from_ticket=source_key
#     - idempotent on same heading (today)
#     - rejects missing ticket_run_dir / missing prompt.md
#   set_amendment_proposal:
#     - persists
#     - rejects malformed proposal (missing field)
#   clear_amendment_proposal:
#     - clears + idempotent
#   find_next_ready_ticket:
#     - pending-amendment-applied IS selectable
#     - amending is NOT selectable
#   validate():
#     - rejects malformed amendment_proposal shape
#   End-to-end 3-ticket synthetic wave:
#     T-A in-progress; T-B depends on T-A; T-C touches a shared file with T-A.
#     Detect on T-A → descriptor; scan → [T-B, T-C]; apply source + per-downstream;
#     prompt.md updated; statuses transition; pending-amendment-applied tickets
#     are selectable via find_next_ready_ticket.
#
# Usage: bash core/scripts/test-wave-manifest-amendment.sh
# Exit 0 = all PASS; exit 1 = at least one FAIL.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(dirname "$REPO_ROOT")"
WM="${REPO_ROOT}/core/scripts/wave-manifest.py"

if [ ! -f "$WM" ]; then
  echo "ERROR: wave-manifest.py not found at $WM" >&2
  exit 1
fi

PASS=0
FAIL=0
FAIL_DETAIL=""

ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); FAIL_DETAIL="${FAIL_DETAIL}
  - $1: $2"; }

SCRATCH=$(mktemp -d)
trap "rm -rf '$SCRATCH'" EXIT

# Build a minimal manifest with three tickets; T-A in-progress, T-B depends on
# T-A and is pending, T-C is pending and shares a planned file with T-A.
build_manifest() {
  local path="$1"
  cat > "$path" <<'EOF'
{
  "wave_slug": "test-wave",
  "wave_run_dir": "/tmp/wave",
  "wave_branch": "feature/wave-test-wave",
  "wave_base_ref": null,
  "ui_addendum_path": null,
  "current_ticket": "T-A",
  "tickets": [
    {
      "key": "T-A",
      "title": "alpha",
      "description": "alpha desc",
      "ticket_run_dir": null,
      "ticket_branch": "feature/wave-test-wave--T-A",
      "depends_on": [],
      "planned_files": ["a/one.py", "a/two.py", "shared/util.py"],
      "gate_recommendations": ["code-reviewer"],
      "manual_review_required": true,
      "status": "in-progress",
      "amendment_history": [],
      "amendment_proposal": null,
      "commit_sha": null,
      "created_at": "2026-05-07T00:00:00Z",
      "completed_at": null
    },
    {
      "key": "T-B",
      "title": "beta",
      "description": "beta desc",
      "ticket_run_dir": "TICKET_B_RUN_DIR_PLACEHOLDER",
      "ticket_branch": "feature/wave-test-wave--T-B",
      "depends_on": ["T-A"],
      "planned_files": ["b/only.py"],
      "gate_recommendations": ["code-reviewer"],
      "manual_review_required": true,
      "status": "pending",
      "amendment_history": [],
      "amendment_proposal": null,
      "commit_sha": null,
      "created_at": "2026-05-07T00:00:00Z",
      "completed_at": null
    },
    {
      "key": "T-C",
      "title": "gamma",
      "description": "gamma desc",
      "ticket_run_dir": "TICKET_C_RUN_DIR_PLACEHOLDER",
      "ticket_branch": "feature/wave-test-wave--T-C",
      "depends_on": [],
      "planned_files": ["shared/util.py", "c/extra.py"],
      "gate_recommendations": ["code-reviewer"],
      "manual_review_required": true,
      "status": "pending",
      "amendment_history": [],
      "amendment_proposal": null,
      "commit_sha": null,
      "created_at": "2026-05-07T00:00:00Z",
      "completed_at": null
    }
  ],
  "deferrals": [],
  "surface_log": "/tmp/wave/surface-log.md"
}
EOF
}

# Helper: run a Python expression against the wave-manifest module; print stdout.
pyrun() {
  python3 - "$@"
}

# ----------------------------------------------------------------------- Tests

echo "detect_amendment: returns None when actual == planned"
MAN="${SCRATCH}/m1.json"
build_manifest "$MAN"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN}')
r = wm.detect_amendment(m, 'T-A', ['a/one.py', 'a/two.py', 'shared/util.py'])
print('NONE' if r is None else 'NOT_NONE')
")
[ "$OUT" = "NONE" ] && ok "no-diff returns None" || ko "no-diff" "got '$OUT'"

echo "detect_amendment: returns descriptor when a file is added"
OUT=$(python3 -c "
import sys, json; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN}')
r = wm.detect_amendment(m, 'T-A', ['a/one.py', 'a/two.py', 'shared/util.py', 'a/three.py'])
print(json.dumps(r, sort_keys=True))
")
ADDED=$(echo "$OUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(','.join(d['added_files']))")
REMOVED=$(echo "$OUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(','.join(d['removed_files']))")
[ "$ADDED" = "a/three.py" ] && [ "$REMOVED" = "" ] \
  && ok "add-one descriptor correct" \
  || ko "add-one descriptor" "added='$ADDED' removed='$REMOVED' raw='$OUT'"

echo "detect_amendment: returns descriptor when a file is removed"
OUT=$(python3 -c "
import sys, json; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN}')
r = wm.detect_amendment(m, 'T-A', ['a/one.py', 'shared/util.py'])
print(json.dumps(r, sort_keys=True))
")
REMOVED=$(echo "$OUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(','.join(d['removed_files']))")
[ "$REMOVED" = "a/two.py" ] && ok "remove-one descriptor correct" \
  || ko "remove-one descriptor" "removed='$REMOVED' raw='$OUT'"

echo "detect_amendment: descriptor includes both added and removed in mixed change"
OUT=$(python3 -c "
import sys, json; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN}')
r = wm.detect_amendment(m, 'T-A', ['a/one.py', 'shared/util.py', 'a/four.py'])
print(json.dumps(r, sort_keys=True))
")
ADDED=$(echo "$OUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(','.join(d['added_files']))")
REMOVED=$(echo "$OUT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(','.join(d['removed_files']))")
[ "$ADDED" = "a/four.py" ] && [ "$REMOVED" = "a/two.py" ] \
  && ok "mixed descriptor correct" \
  || ko "mixed descriptor" "added='$ADDED' removed='$REMOVED'"

echo "detect_amendment: raises on unknown ticket_key"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN}')
try:
    wm.detect_amendment(m, 'T-NOPE', ['a/one.py'])
    print('NO_RAISE')
except ValueError as e:
    print('RAISED')
")
[ "$OUT" = "RAISED" ] && ok "raises on unknown ticket_key" || ko "unknown-key raise" "got '$OUT'"

echo "scan_downstream_impact: T-A → [T-B (depends_on), T-C (planned_files intersect)]"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN}')
print(','.join(wm.scan_downstream_impact(m, 'T-A')))
")
[ "$OUT" = "T-B,T-C" ] && ok "scan returns both downstream" \
  || ko "scan downstream" "expected 'T-B,T-C' got '$OUT'"

echo "scan_downstream_impact: source ticket excluded from its own scan"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN}')
print('YES' if 'T-A' in wm.scan_downstream_impact(m, 'T-A') else 'NO')
")
[ "$OUT" = "NO" ] && ok "source excluded" || ko "source self-exclude" "got '$OUT'"

echo "scan_downstream_impact: status 'complete' tickets are excluded"
MAN2="${SCRATCH}/m2.json"
build_manifest "$MAN2"
python3 -c "
import json
m = json.load(open('${MAN2}'))
for t in m['tickets']:
    if t['key'] == 'T-C':
        t['status'] = 'complete'
json.dump(m, open('${MAN2}', 'w'))
"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN2}')
print(','.join(wm.scan_downstream_impact(m, 'T-A')))
")
[ "$OUT" = "T-B" ] && ok "complete excluded" || ko "complete exclude" "got '$OUT' (expected 'T-B' only)"

echo "scan_downstream_impact: status 'blocked' tickets are excluded"
MAN3="${SCRATCH}/m3.json"
build_manifest "$MAN3"
python3 -c "
import json
m = json.load(open('${MAN3}'))
for t in m['tickets']:
    if t['key'] == 'T-B':
        t['status'] = 'blocked'
json.dump(m, open('${MAN3}', 'w'))
"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN3}')
print(','.join(wm.scan_downstream_impact(m, 'T-A')))
")
[ "$OUT" = "T-C" ] && ok "blocked excluded" || ko "blocked exclude" "got '$OUT' (expected 'T-C' only)"

echo "apply_amendment_source: unions planned_files, status in-progress → amending"
MAN4="${SCRATCH}/m4.json"
build_manifest "$MAN4"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
wm.apply_amendment_source('${MAN4}', 'T-A',
                          ['a/one.py', 'a/two.py', 'shared/util.py', 'a/three.py'],
                          'T-A: added 1 file(s): a/three.py')
"
PF=$(python3 -c "import json; m=json.load(open('${MAN4}'));
print(','.join([t['planned_files'] for t in m['tickets'] if t['key']=='T-A'][0]))")
ST=$(python3 -c "import json; m=json.load(open('${MAN4}'));
print([t['status'] for t in m['tickets'] if t['key']=='T-A'][0])")
HSZ=$(python3 -c "import json; m=json.load(open('${MAN4}'));
print(len([t['amendment_history'] for t in m['tickets'] if t['key']=='T-A'][0]))")
HSELF=$(python3 -c "import json; m=json.load(open('${MAN4}'));
h=[t['amendment_history'] for t in m['tickets'] if t['key']=='T-A'][0];
print(h[0]['from_ticket'] if h else '')")
[ "$PF" = "a/one.py,a/three.py,a/two.py,shared/util.py" ] \
  && [ "$ST" = "amending" ] && [ "$HSZ" = "1" ] && [ "$HSELF" = "T-A" ] \
  && ok "source apply: union+status+history correct" \
  || ko "source apply" "pf='$PF' st='$ST' hsz='$HSZ' hself='$HSELF'"

echo "apply_amendment_source: idempotent on same delta_summary"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
wm.apply_amendment_source('${MAN4}', 'T-A',
                          ['a/one.py', 'a/two.py', 'shared/util.py', 'a/three.py'],
                          'T-A: added 1 file(s): a/three.py')
"
HSZ2=$(python3 -c "import json; m=json.load(open('${MAN4}'));
print(len([t['amendment_history'] for t in m['tickets'] if t['key']=='T-A'][0]))")
[ "$HSZ2" = "1" ] && ok "source apply idempotent" || ko "source idempotent" "history grew to '$HSZ2'"

echo "apply_amendment_downstream: appends prompt.md, status pending → pending-amendment-applied"
MAN5="${SCRATCH}/m5.json"
build_manifest "$MAN5"
TBDIR="${SCRATCH}/T-B-rundir"
mkdir -p "$TBDIR"
echo "# T-B initial prompt" > "$TBDIR/prompt.md"
python3 -c "
import json
m = json.load(open('${MAN5}'))
for t in m['tickets']:
    if t['key'] == 'T-B':
        t['ticket_run_dir'] = '${TBDIR}'
json.dump(m, open('${MAN5}', 'w'))
"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
wm.apply_amendment_downstream('${MAN5}', 'T-B', 'T-A',
                              'T-A amended its scope: added a/three.py.\n\nImpact: review interface.')
"
ST=$(python3 -c "import json; m=json.load(open('${MAN5}'));
print([t['status'] for t in m['tickets'] if t['key']=='T-B'][0])")
HASHEAD=$(grep -c "^## Amendment from T-A" "$TBDIR/prompt.md" || true)
HFROM=$(python3 -c "import json; m=json.load(open('${MAN5}'));
h=[t['amendment_history'] for t in m['tickets'] if t['key']=='T-B'][0];
print(h[0]['from_ticket'] if h else '')")
[ "$ST" = "pending-amendment-applied" ] && [ "$HASHEAD" = "1" ] && [ "$HFROM" = "T-A" ] \
  && ok "downstream apply: prompt+status+history correct" \
  || ko "downstream apply" "st='$ST' headcount='$HASHEAD' hfrom='$HFROM'"

echo "apply_amendment_downstream: idempotent on same heading (today)"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
wm.apply_amendment_downstream('${MAN5}', 'T-B', 'T-A',
                              'T-A amended its scope: added a/three.py.\n\nImpact: review interface.')
"
HC2=$(grep -c "^## Amendment from T-A" "$TBDIR/prompt.md" || true)
HSZ=$(python3 -c "import json; m=json.load(open('${MAN5}'));
print(len([t['amendment_history'] for t in m['tickets'] if t['key']=='T-B'][0]))")
[ "$HC2" = "1" ] && [ "$HSZ" = "1" ] && ok "downstream apply idempotent" \
  || ko "downstream idempotent" "headcount='$HC2' hsz='$HSZ'"

echo "apply_amendment_downstream: rejects missing ticket_run_dir"
MAN6="${SCRATCH}/m6.json"
build_manifest "$MAN6"
# T-B already has TICKET_B_RUN_DIR_PLACEHOLDER literally; use null for clarity
python3 -c "
import json
m = json.load(open('${MAN6}'))
for t in m['tickets']:
    if t['key'] == 'T-B':
        t['ticket_run_dir'] = None
json.dump(m, open('${MAN6}', 'w'))
"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
try:
    wm.apply_amendment_downstream('${MAN6}', 'T-B', 'T-A', 'amend text')
    print('NO_RAISE')
except ValueError:
    print('RAISED')
")
[ "$OUT" = "RAISED" ] && ok "downstream rejects missing ticket_run_dir" \
  || ko "downstream missing-rundir" "got '$OUT'"

echo "apply_amendment_downstream: rejects missing prompt.md (CR-005 iter-2 coverage)"
MAN6B="${SCRATCH}/m6b.json"
build_manifest "$MAN6B"
TBDIR_NOPROMPT="${SCRATCH}/T-B-rundir-no-prompt"
mkdir -p "$TBDIR_NOPROMPT"
# Intentionally do NOT create prompt.md inside this directory.
python3 -c "
import json
m = json.load(open('${MAN6B}'))
for t in m['tickets']:
    if t['key'] == 'T-B':
        t['ticket_run_dir'] = '${TBDIR_NOPROMPT}'
json.dump(m, open('${MAN6B}', 'w'))
"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
try:
    wm.apply_amendment_downstream('${MAN6B}', 'T-B', 'T-A', 'amend text')
    print('NO_RAISE')
except ValueError as e:
    print('RAISED' if 'prompt.md not found' in str(e) else f'WRONG_RAISE:{e}')
")
[ "$OUT" = "RAISED" ] && ok "downstream rejects missing prompt.md" \
  || ko "downstream missing-prompt" "got '$OUT'"

echo "apply_amendment_downstream: rejects path-traversal in ticket_run_dir (SA-002 iter-2 coverage)"
MAN6C="${SCRATCH}/m6c.json"
build_manifest "$MAN6C"
# Set ticket_run_dir to a path that resolves outside the manifest's directory.
# The manifest is at $SCRATCH/m6c.json, so manifest_root realpath = $SCRATCH.
# We point ticket_run_dir at /tmp (outside $SCRATCH) and create a prompt.md
# there — the realpath check should refuse the write regardless.
TRAVERSAL_DIR=$(mktemp -d -t outside-scratch-XXXXXX)
mkdir -p "$TRAVERSAL_DIR"
echo "# malicious target prompt" > "$TRAVERSAL_DIR/prompt.md"
python3 -c "
import json
m = json.load(open('${MAN6C}'))
for t in m['tickets']:
    if t['key'] == 'T-B':
        t['ticket_run_dir'] = '${TRAVERSAL_DIR}'
json.dump(m, open('${MAN6C}', 'w'))
"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
try:
    wm.apply_amendment_downstream('${MAN6C}', 'T-B', 'T-A', 'attacker-controlled amend')
    print('NO_RAISE')
except ValueError as e:
    print('RAISED' if 'outside the wave run directory' in str(e) else f'WRONG_RAISE:{e}')
")
# Verify the traversal target was NOT modified (the realpath check refused the write).
TRAVERSAL_PROMPT_BYTES=$(wc -c < "$TRAVERSAL_DIR/prompt.md")
EXPECTED_BYTES=$(printf '%s' "# malicious target prompt
" | wc -c)
[ "$OUT" = "RAISED" ] && [ "$TRAVERSAL_PROMPT_BYTES" = "$EXPECTED_BYTES" ] \
  && ok "downstream rejects path-traversal in ticket_run_dir + target file unmodified" \
  || ko "downstream traversal" "out='$OUT' traversal_bytes=$TRAVERSAL_PROMPT_BYTES expected=$EXPECTED_BYTES"
rm -rf "$TRAVERSAL_DIR"

echo "validate(): rejects affected_downstream entries that don't match TICKET_KEY_RE (SA-003 iter-2 coverage)"
MAN6D="${SCRATCH}/m6d.json"
build_manifest "$MAN6D"
python3 -c "
import json
m = json.load(open('${MAN6D}'))
for t in m['tickets']:
    if t['key'] == 'T-A':
        t['amendment_proposal'] = {
            'detected_at': '2026-05-07T00:00:00Z',
            'actual_files_modified': ['a/one.py'],
            'added_files': [],
            'removed_files': [],
            'delta_summary': 'x',
            'affected_downstream': ['T-B', '../../../etc/passwd'],
            'proposed_text_per_downstream': {'T-B': 'ok'}
        }
json.dump(m, open('${MAN6D}', 'w'))
"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN6D}')
errs = wm.validate(m)
print('REJECT' if any('affected_downstream' in e and 'must match' in e for e in errs) else 'ACCEPT')
")
[ "$OUT" = "REJECT" ] && ok "validate rejects malformed affected_downstream key" \
  || ko "validate affected_downstream regex" "got '$OUT'"

echo "set_amendment_proposal: persists; rejects missing required field"
MAN7="${SCRATCH}/m7.json"
build_manifest "$MAN7"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
proposal = {
    'detected_at': '2026-05-07T00:00:00Z',
    'actual_files_modified': ['a/one.py', 'a/two.py', 'shared/util.py', 'a/three.py'],
    'added_files': ['a/three.py'],
    'removed_files': [],
    'delta_summary': 'T-A: added 1 file(s): a/three.py',
    'affected_downstream': ['T-B', 'T-C'],
    'proposed_text_per_downstream': {'T-B': 'amend B text', 'T-C': 'amend C text'},
}
wm.set_amendment_proposal('${MAN7}', 'T-A', proposal)
"
APR=$(python3 -c "import json; m=json.load(open('${MAN7}'));
print('SET' if [t['amendment_proposal'] for t in m['tickets'] if t['key']=='T-A'][0] is not None else 'NULL')")
[ "$APR" = "SET" ] && ok "set_amendment_proposal persisted" \
  || ko "set_amendment_proposal persist" "got '$APR'"

OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
try:
    wm.set_amendment_proposal('${MAN7}', 'T-A', {'detected_at': 'x'})
    print('NO_RAISE')
except ValueError:
    print('RAISED')
")
[ "$OUT" = "RAISED" ] && ok "set_amendment_proposal validates required" \
  || ko "set_amendment_proposal validate" "got '$OUT'"

echo "clear_amendment_proposal: clears + idempotent"
python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
wm.clear_amendment_proposal('${MAN7}', 'T-A')
wm.clear_amendment_proposal('${MAN7}', 'T-A')  # idempotent
"
APR=$(python3 -c "import json; m=json.load(open('${MAN7}'));
print('SET' if [t['amendment_proposal'] for t in m['tickets'] if t['key']=='T-A'][0] is not None else 'NULL')")
[ "$APR" = "NULL" ] && ok "clear_amendment_proposal cleared + idempotent" \
  || ko "clear_amendment_proposal" "got '$APR'"

echo "find_next_ready_ticket: pending-amendment-applied IS selectable"
MAN8="${SCRATCH}/m8.json"
build_manifest "$MAN8"
# Mark T-A complete and T-B as pending-amendment-applied
python3 -c "
import json
m = json.load(open('${MAN8}'))
for t in m['tickets']:
    if t['key'] == 'T-A':
        t['status'] = 'complete'
    if t['key'] == 'T-B':
        t['status'] = 'pending-amendment-applied'
    if t['key'] == 'T-C':
        t['status'] = 'complete'
json.dump(m, open('${MAN8}', 'w'))
"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN8}')
print(wm.find_next_ready_ticket(m))
")
[ "$OUT" = "T-B" ] && ok "find_next_ready_ticket selects pending-amendment-applied" \
  || ko "selectable pending-amendment-applied" "got '$OUT'"

echo "find_next_ready_ticket: 'amending' is NOT selectable (mid-flight)"
MAN9="${SCRATCH}/m9.json"
build_manifest "$MAN9"
python3 -c "
import json
m = json.load(open('${MAN9}'))
for t in m['tickets']:
    if t['key'] == 'T-A':
        t['status'] = 'amending'
    if t['key'] == 'T-B':
        t['status'] = 'complete'
    if t['key'] == 'T-C':
        t['status'] = 'complete'
json.dump(m, open('${MAN9}', 'w'))
"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN9}')
r = wm.find_next_ready_ticket(m)
print('NONE' if r is None else r)
")
[ "$OUT" = "NONE" ] && ok "find_next_ready_ticket excludes 'amending'" \
  || ko "amending excluded" "got '$OUT'"

echo "validate(): rejects malformed amendment_proposal (non-dict, missing field)"
MAN10="${SCRATCH}/m10.json"
build_manifest "$MAN10"
# Inject a malformed amendment_proposal (string instead of dict)
python3 -c "
import json
m = json.load(open('${MAN10}'))
for t in m['tickets']:
    if t['key'] == 'T-A':
        t['amendment_proposal'] = 'not-a-dict'
json.dump(m, open('${MAN10}', 'w'))
"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN10}')
errs = wm.validate(m)
print('REJECT' if any('amendment_proposal' in e for e in errs) else 'ACCEPT')
")
[ "$OUT" = "REJECT" ] && ok "validate rejects malformed amendment_proposal" \
  || ko "validate amendment_proposal" "got '$OUT'"

# Inject a malformed amendment_proposal (dict missing required fields)
python3 -c "
import json
m = json.load(open('${MAN10}'))
for t in m['tickets']:
    if t['key'] == 'T-A':
        t['amendment_proposal'] = {'detected_at': 'x'}
json.dump(m, open('${MAN10}', 'w'))
"
OUT=$(python3 -c "
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)
m = wm.read_manifest('${MAN10}')
errs = wm.validate(m)
print('REJECT' if any('missing required field' in e for e in errs) else 'ACCEPT')
")
[ "$OUT" = "REJECT" ] && ok "validate rejects amendment_proposal missing required fields" \
  || ko "validate amendment_proposal missing-fields" "got '$OUT'"

echo "End-to-end: 3-ticket synthetic amendment flow"
MANE="${SCRATCH}/me.json"
build_manifest "$MANE"
TBDIRE="${SCRATCH}/E-T-B-rundir"
TCDIRE="${SCRATCH}/E-T-C-rundir"
mkdir -p "$TBDIRE" "$TCDIRE"
echo "# T-B initial" > "$TBDIRE/prompt.md"
echo "# T-C initial" > "$TCDIRE/prompt.md"
python3 -c "
import json
m = json.load(open('${MANE}'))
for t in m['tickets']:
    if t['key'] == 'T-B':
        t['ticket_run_dir'] = '${TBDIRE}'
    if t['key'] == 'T-C':
        t['ticket_run_dir'] = '${TCDIRE}'
json.dump(m, open('${MANE}', 'w'))
"
python3 - <<PYEOF
import sys; sys.path.insert(0, '${REPO_ROOT}/core/scripts')
import importlib.util
spec = importlib.util.spec_from_file_location('wm', '${WM}')
wm = importlib.util.module_from_spec(spec); spec.loader.exec_module(wm)

m = wm.read_manifest('${MANE}')
descriptor = wm.detect_amendment(m, 'T-A',
    ['a/one.py', 'a/two.py', 'shared/util.py', 'a/three.py'])
assert descriptor is not None, "expected non-None descriptor"
assert descriptor['added_files'] == ['a/three.py'], descriptor

affected = wm.scan_downstream_impact(m, 'T-A')
assert affected == ['T-B', 'T-C'], affected

# Persist proposal first
proposal = {
    'detected_at': '2026-05-07T00:00:00Z',
    'actual_files_modified': descriptor['actual_files_modified'],
    'added_files': descriptor['added_files'],
    'removed_files': descriptor['removed_files'],
    'delta_summary': descriptor['delta_summary'],
    'affected_downstream': affected,
    'proposed_text_per_downstream': {
        'T-B': 'T-A added a/three.py.\\n\\nImpact: review T-B integration.',
        'T-C': 'T-A added a/three.py touching shared/util.py.\\n\\nImpact: re-validate.'
    }
}
wm.set_amendment_proposal('${MANE}', 'T-A', proposal)

# Apply source then both downstreams
wm.apply_amendment_source('${MANE}', 'T-A',
    descriptor['actual_files_modified'], descriptor['delta_summary'])
wm.apply_amendment_downstream('${MANE}', 'T-B', 'T-A', proposal['proposed_text_per_downstream']['T-B'])
wm.apply_amendment_downstream('${MANE}', 'T-C', 'T-A', proposal['proposed_text_per_downstream']['T-C'])

# Clear proposal
wm.clear_amendment_proposal('${MANE}', 'T-A')

# Verify final state
final = wm.read_manifest('${MANE}')
ta = next(t for t in final['tickets'] if t['key'] == 'T-A')
tb = next(t for t in final['tickets'] if t['key'] == 'T-B')
tc = next(t for t in final['tickets'] if t['key'] == 'T-C')

assert ta['status'] == 'amending', ta['status']
assert ta['amendment_proposal'] is None
assert 'a/three.py' in ta['planned_files']
assert tb['status'] == 'pending-amendment-applied'
assert tc['status'] == 'pending-amendment-applied'

# T-A is amending so not yet complete; T-A.depends_on = []. T-B's deps = ['T-A'] still
# pending. T-C's deps = []. find_next_ready_ticket should return T-C
# (lower key than T-B in sorted order, both pending-amendment-applied or pending,
# but T-B is blocked on T-A's completion).
nxt = wm.find_next_ready_ticket(final)
assert nxt == 'T-C', f"expected T-C, got {nxt}"

print("END_TO_END_OK")
PYEOF
[ "$?" = "0" ] && ok "end-to-end 3-ticket flow" || ko "end-to-end" "see above"

# ----------------------------------------------------------------------- Verdict

echo
echo "===================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "FAIL DETAIL:$FAIL_DETAIL"
  exit 1
fi
exit 0
