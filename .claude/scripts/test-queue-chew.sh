#!/usr/bin/env bash
# Synthetic test for the /queue-chew daemon's RESUME selection (ADR-122, AWQ-T7; AC-020).
#
# AC-020 requires a REAL executable assertion that a simulated mid-drain restart resumes from the
# next pending item WITHOUT re-building a `done/` item. The daemon keeps NO in-memory state (ADR-093
# overnight-resume): on restart it re-reads `docs/step-4-queue/`, sees which entries are in `done/` vs
# `pending/`, and resumes from the next dep-ready `pending/` item. Because state IS location (folder)
# and `git mv` transitions are atomic, resume is lossless and mop-up is idempotent (location-is-status,
# ADR-087). This harness sets up a temp pending/+done/ folder state and asserts:
#   (1) a `done/` item is NEVER re-selected on restart (glob-never-re-picks, Wave-2 AC-013);
#   (2) the next dep-ready `pending/` item IS selected (resume-from-next);
#   (3) an item whose `after` dep is still in pending/ (not done/) is NOT selected (dep-gated);
#   (4) re-running the same selection twice yields the same pick (idempotent mop-up).
#
# `pick_next` below is the daemon's documented selection contract (core/skills/queue-chew/SKILL.md
# § The iteration loop, step 2: "the earliest-`seq` entry whose `after` deps are all already in
# done/") realized as a standalone shell function so the property is EXECUTABLE, not prose-only.
# It does not import the skill; it re-states the same deterministic selection over the live folders.
set -uo pipefail
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
Q="$W/queue"
mkdir -p "$Q/pending" "$Q/running" "$Q/done" "$Q/failed"

# Helper: write a queue entry in the ENTRY-AS-FOLDER shape (ADR-124) into a lifecycle subfolder:
#   <stage>/<label>/ holds the moved source artifact (<label>.md) + sidecar.json {label,verb,seq,...,target}.
# This mirrors how Wave-1 `/queue add` (folder move-in) + the daemon's `git mv` lifecycle leave it on disk.
# args: stage label seq [after_csv]
write_entry() {
  local stage="$1" label="$2" seq="$3" after="${4:-}"
  mkdir -p "$Q/$stage/$label"
  : > "$Q/$stage/$label/$label.md"
  python3 - "$Q/$stage/$label/sidecar.json" "$label" "$seq" "$after" <<'PYEOF'
import json, sys
path, label, seq, after = sys.argv[1:5]
side = {"verb": "orchestrated", "label": label, "seq": int(seq), "target": "."}
if after:
    side["after"] = [a for a in after.split(",") if a]
json.dump(side, open(path, "w"))
PYEOF
}

# pick_next QUEUE_DIR  -> prints the entry-folder basename of the next dep-ready pending entry (earliest seq
#   whose every `after` dep is already present in done/), or "" if none is dep-ready. This is the daemon's
#   documented restart selection over the ENTRY-AS-FOLDER shape (re-derives from the FOLDER; no in-memory
#   state — ADR-093). It iterates pending/*/sidecar.json (one entry per subdir), NOT pending/*.md.
pick_next() {
  local q="$1"
  python3 - "$q" <<'PYEOF'
import json, os, sys, glob
q = sys.argv[1]
done = {os.path.basename(p.rstrip("/")) for p in glob.glob(os.path.join(q, "done", "*/"))}
cands = []
for side_path in sorted(glob.glob(os.path.join(q, "pending", "*", "sidecar.json"))):
    entry = os.path.basename(os.path.dirname(side_path))
    seq, after = 0, []
    try:
        side = json.load(open(side_path))
        seq = side.get("seq", 0)
        after = side.get("after", []) or []
        if isinstance(after, str):
            after = [after]
    except Exception:
        pass
    # dep-ready iff every `after` dep is already in done/
    if all(dep in done for dep in after):
        cands.append((seq, entry))
cands.sort()
print(cands[0][1] if cands else "")
PYEOF
}

# --- Fixture: a mid-drain restart state. A and B already drained (in done/); C and D still pending.
#     D declares `after C` (dep NOT yet satisfied — C is in pending/, not done/). C is independent. ---
write_entry done    A 100
write_entry done    B 200
write_entry pending C 300
write_entry pending D 400 C

# --- 1. Restart resumes from the next pending item, NEVER re-picking a done/ one ---
PICK=$(pick_next "$Q")
[ "$PICK" = "C" ] && ok "restart resumes from next pending item (C), not a done/ item" \
  || ko "resume-from-next" "expected C, got '$PICK'"

# --- 2. A done/ item (A, B) is NEVER re-selected (glob-never-re-picks) ---
case "$PICK" in
  A|B) ko "glob-never-re-picks" "re-picked a done/ item '$PICK' — DOUBLE-BUILD bug" ;;
  *)   ok "done/ items A,B are never re-selected on restart (glob-never-re-picks, no double-build)" ;;
esac

# --- 3. D is dep-gated: its `after C` is unsatisfied (C still pending), so D is NOT selected yet ---
[ "$PICK" != "D" ] && ok "dep-gated item D (after C, C not yet done/) is NOT selected before C" \
  || ko "dep-gated" "selected D while its dep C is still pending"

# --- 4. Idempotent mop-up: re-running selection on the SAME unchanged folder yields the SAME pick ---
PICK2=$(pick_next "$Q")
[ "$PICK2" = "$PICK" ] && ok "selection is idempotent (re-deriving from folder yields the same pick)" \
  || ko "idempotent" "first='$PICK' second='$PICK2'"

# --- 5. After C drains (simulate the daemon moving C pending/ -> done/), D becomes dep-ready ---
#     (the daemon uses `git mv`; the fixture uses plain mv — the selection reads location, not VCS state)
#     The whole entry FOLDER moves (ADR-124 entry-as-folder), not individual files.
mv "$Q/pending/C" "$Q/done/C"
PICK3=$(pick_next "$Q")
[ "$PICK3" = "D" ] && ok "after C drains to done/, D becomes dep-ready and is selected next" \
  || ko "dep-unblock" "expected D after C done, got '$PICK3'"

# --- 6. Fully drained queue (move D to done/) -> no pick (clean termination, WRAP point) ---
mv "$Q/pending/D" "$Q/done/D"
PICK4=$(pick_next "$Q")
[ -z "$PICK4" ] && ok "fully-drained queue yields no pick (termination / WRAP point)" \
  || ko "drained" "expected empty, got '$PICK4'"

echo ""
echo "queue-chew resume: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
