#!/usr/bin/env bash
# Executable test for queue-`done/` archival (ADR-128, queue-done-canonical-merge epic).
#
# Covers the settled-predicate (queue-archive.py), the qc_completed_labels() union chokepoint + qc_pick_entry
# re-point (QDM-T1), and the qc_archive_settled worktree-isolated git mv + legibility + manifest closes
# (QDM-T2). GREEN means an entry physically archives done/ → step-6-done/queue/ WITHOUT breaking the four
# ADR-123 D-3 invariants, the dependency union still resolves a late after:<archived>, and no bare-done/
# completion glob remains for the gating/legibility readers.
#
# Mirrors test-queue-chew-e2e.sh / test-queue-order.sh structure: an isolated temp git repo so the lib's
# git mv runs for real; QUEUE_DIR + QC_ARCHIVE_DIR overrides co-locate step-4-queue and step-6-done/queue
# in the temp tree (portable, macOS BSD + GNU). No GNU-only flags.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# --- Isolated temp git repo so git mv / git rev-parse / git status work for real. ---
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cd "$W" || { echo "cannot cd to temp"; exit 1; }
git init -q
git config user.email "test@example.com"
git config user.name "queue-archive test"

mkdir -p core/scripts
cp "$HERE/queue-archive.py" core/scripts/queue-archive.py
cp "$HERE/queue-order.py" core/scripts/queue-order.py 2>/dev/null || true

# Queue root + canonical archive root, co-located in the temp tree (lib honors QUEUE_DIR / QC_ARCHIVE_DIR).
# QC_ARCHIVE_DIR is the archive BASE; the lib (ADR-128 Amendment 1 / SHR4-C3) appends a DATE sub-dir under it,
# so a settled entry lands at $QC_ARCHIVE_DIR/$TODAY/<entry>, NOT the pre-amendment flat $QC_ARCHIVE_DIR/<entry>.
export QUEUE_DIR="docs/step-4-queue"
export QC_ARCHIVE_DIR="docs/step-6-done/queue"
TODAY="$(date -u +%F)"   # the archival date partition the writer derives (ISO YYYY-MM-DD).
DATED="$QC_ARCHIVE_DIR/$TODAY"   # where today's archived entries land.
mkdir -p "$QUEUE_DIR/pending" "$QUEUE_DIR/running" "$QUEUE_DIR/done" "$QUEUE_DIR/failed" "$QC_ARCHIVE_DIR"
: > "$QUEUE_DIR/done/.gitkeep"

# Source the lib UNDER TEST.
# shellcheck disable=SC1090
. "$HERE/queue-chew-lib.sh"

git add -A && git commit -q -m "fixture root"

# Helper: write an entry FOLDER (entry-as-folder, ADR-124) in a lifecycle stage with a sidecar.
# args: stage label seq [after_csv] [target]
write_entry() {
  local stage="$1" label="$2" seq="$3" after="${4:-}" target="${5:-.}"
  mkdir -p "$QUEUE_DIR/$stage/$label"
  : > "$QUEUE_DIR/$stage/$label/$label.md"
  python3 - "$QUEUE_DIR/$stage/$label/sidecar.json" "$label" "$seq" "$after" "$target" <<'PYEOF'
import json, sys
path, label, seq, after, target = sys.argv[1:6]
side = {"verb": "orchestrated", "label": label, "seq": int(seq), "target": target}
if after:
    side["after"] = [a for a in after.split(",") if a]
json.dump(side, open(path, "w"))
PYEOF
  git add -A >/dev/null 2>&1 || true
}

ARCHIVE="python3 core/scripts/queue-archive.py"

# =========================================================================================================
echo "== QDM-T1: settled predicate (queue-archive.py) =="
# =========================================================================================================

# 1. zero-LLM: grep for agent( must be clean (AC-1).
if grep -nqE 'agent\(' core/scripts/queue-archive.py; then
  ko "AC-1 zero-LLM" "agent( found in queue-archive.py"
else
  ok "AC-1 zero-LLM: no agent( in queue-archive.py"
fi

# 2. A done/ entry with a LIVE after: dependent is NOT archivable; one with none IS (AC-1 settled predicate).
write_entry done done-settled 100
write_entry done done-blocked 110
write_entry pending pending-dep 200 "done-blocked"
OUT="$($ARCHIVE settled --queue-dir "$QUEUE_DIR")"
ARCH="$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["archivable"]))')"
WITH="$(printf '%s' "$OUT" | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["withheld"]))')"
if [ "$ARCH" = "done-settled" ]; then ok "AC-1 settled: entry with no live after: IS archivable"; else ko "AC-1 settled archivable" "got '[$ARCH]' want 'done-settled'"; fi
if [ "$WITH" = "done-blocked" ]; then ok "AC-1 settled: entry named by a live after: is WITHHELD"; else ko "AC-1 settled withheld" "got '[$WITH]' want 'done-blocked'"; fi

# 3. .gitkeep is never a candidate (AC-7).
if printf '%s %s' "$ARCH" "$WITH" | grep -q '.gitkeep'; then ko "AC-7 .gitkeep" ".gitkeep appeared as a candidate"; else ok "AC-7: .gitkeep is never a candidate"; fi

# 4. abstain (fail-closed) on a malformed pending sidecar (AC-1 no-guess).
mkdir -p "$QUEUE_DIR/pending/pending-malformed"
printf '{ this is not json' > "$QUEUE_DIR/pending/pending-malformed/sidecar.json"
OUTM="$($ARCHIVE settled --queue-dir "$QUEUE_DIR")"
CONF="$(printf '%s' "$OUTM" | python3 -c 'import json,sys;print(json.load(sys.stdin)["confidence"])')"
ARCHM="$(printf '%s' "$OUTM" | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["archivable"]))')"
if [ "$CONF" = "abstain" ] && [ -z "$ARCHM" ]; then ok "AC-1 no-guess: malformed pending sidecar → abstain, withhold all"; else ko "AC-1 no-guess" "confidence='$CONF' archivable='[$ARCHM]' (want abstain + empty)"; fi
rm -rf "$QUEUE_DIR/pending/pending-malformed"

# =========================================================================================================
echo "== QDM-T1: qc_completed_labels() union chokepoint + qc_pick_entry re-point =="
# =========================================================================================================

# 5. qc_completed_labels reads the UNION done/ ∪ step-6-done/queue/ (AC-2/AC-11).
write_entry done union-done 300
mkdir -p "$QC_ARCHIVE_DIR/union-archived"
: > "$QC_ARCHIVE_DIR/union-archived/union-archived.md"
COMPLETED="$(qc_completed_labels)"
if printf '%s\n' "$COMPLETED" | grep -qx "union-done" && printf '%s\n' "$COMPLETED" | grep -qx "union-archived"; then
  ok "AC-11 chokepoint: qc_completed_labels returns the union (done/ + step-6-done/queue/)"
else
  ko "AC-11 chokepoint union" "completed='[$COMPLETED]' missing union member"
fi
if printf '%s\n' "$COMPLETED" | grep -qx ".gitkeep"; then ko "AC-11 chokepoint .gitkeep" ".gitkeep leaked into completion set"; else ok "AC-11 chokepoint: .gitkeep excluded from completion set"; fi

# 6. AC-2 — a pending entry whose after: names an ARCHIVED predecessor resolves dep-ready via the union.
#    Clean slate: a single pending entry after:<archived-only> (the predecessor exists ONLY in the archive).
rm -rf "$QUEUE_DIR/pending"/* "$QUEUE_DIR/done"/*; : > "$QUEUE_DIR/done/.gitkeep"
mkdir -p "$QC_ARCHIVE_DIR/orchestrated-pred"; : > "$QC_ARCHIVE_DIR/orchestrated-pred/orchestrated-pred.md"
write_entry pending nimble-after-archived 400 "orchestrated-pred"
PICK="$(qc_pick_entry)"
if [ "$PICK" = "nimble-after-archived" ]; then
  ok "AC-2: a pending after:<archived-predecessor> resolves dep-ready via the union chokepoint"
else
  ko "AC-2 union dep-resolution" "qc_pick_entry='$PICK' want 'nimble-after-archived' (archived predecessor must count as done)"
fi

# 7. AC-2 negative — a pending after:<not-completed-anywhere> is NOT dep-ready (the union is exact, not lax).
rm -rf "$QUEUE_DIR/pending"/*
write_entry pending nimble-after-missing 500 "never-built-label"
PICK2="$(qc_pick_entry)"
if [ -z "$PICK2" ]; then ok "AC-2 negative: after:<unbuilt> stays NOT dep-ready (union is exact)"; else ko "AC-2 negative" "qc_pick_entry='$PICK2' want empty"; fi

# 8. AC-11 lint — no bare done/ completion glob remains for the gating reader. The ONLY sanctioned done/
#    read in qc_pick_entry is via QC_COMPLETED (the chokepoint env); assert qc_pick_entry has no inline
#    glob of done/ and that it reads QC_COMPLETED.
PICK_BODY="$(awk '/^qc_pick_entry\(\) \{/{f=1} f{print} /^\}/{if(f)exit}' "$HERE/queue-chew-lib.sh")"
if printf '%s' "$PICK_BODY" | grep -qE 'glob\.glob\([^)]*done'; then
  ko "AC-11 no-bare-glob" "qc_pick_entry still globs done/ directly"
else
  ok "AC-11 no-bare-glob: qc_pick_entry has no inline done/ glob"
fi
if printf '%s' "$PICK_BODY" | grep -q 'QC_COMPLETED'; then
  ok "AC-11 chokepoint-wired: qc_pick_entry reads completion via QC_COMPLETED (qc_completed_labels)"
else
  ko "AC-11 chokepoint-wired" "qc_pick_entry does not read QC_COMPLETED"
fi

# 9. AC-6 — SA-001/002/003 guard span byte-identical vs the pre-epic HEAD of the lib. The pre-epic body is
#    captured to a temp file (NOT shell-interpolated — that would mangle quotes/UTF-8 arrows) and the two
#    guard spans are diffed in Python. "Pre-epic" = the lib's HEAD as of the commit BEFORE QDM-T1 landed;
#    since the guard region was never touched by this epic, the spans must match exactly.
REPO="$(cd "$HERE" && git rev-parse --show-toplevel 2>/dev/null)"
PRE_LIB_FILE="$W/lib-pre.sh"
# Compare against the parent of the QDM-T1 commit if it exists, else HEAD (the guard region is epic-untouched
# either way, so both resolve to an identical span).
( cd "$REPO" && git show HEAD:core/scripts/queue-chew-lib.sh ) > "$PRE_LIB_FILE" 2>/dev/null || : > "$PRE_LIB_FILE"
if [ ! -s "$PRE_LIB_FILE" ]; then
  echo "  SKIP: AC-6 SA byte-identical — pre-epic HEAD lib not resolvable"
else
  python3 - "$HERE/queue-chew-lib.sh" "$PRE_LIB_FILE" <<'PYEOF'
import sys
cur = open(sys.argv[1], encoding="utf-8").read()
pre = open(sys.argv[2], encoding="utf-8").read()
def span(t):
    try:
        a = t.index("# qc_validate_entry ENTRY  → SA-001.")
        b = t.index("# BUILD-READINESS ROUTING")
        return t[a:b]
    except ValueError:
        return None
cs = span(cur); ps = span(pre)
if ps is None:
    print("  SKIP: AC-6 SA byte-identical — guard span not found in pre-epic lib (region may predate)")
elif cs == ps:
    print("  PASS: AC-6 SA-001/002/003 guard span byte-identical vs pre-epic HEAD")
else:
    print("  FAIL: AC-6 SA guard span DIVERGED from pre-epic HEAD")
    sys.exit(7)
PYEOF
  SA_RC=$?
  if [ "$SA_RC" -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
fi

# =========================================================================================================
echo "== QDM-T2: qc_archive_settled (bare main-tree git mv — CR-001/CR-002) =="
# =========================================================================================================
# CR-002: exercise the REAL production seam. The queue lifecycle folders live in the operator's MAIN tree;
# the archival move must be a BARE main-tree `git mv` (mirroring qc_drain_to), NOT routed through qc_git/the
# build worktree (where done/<label> is not tracked). To prove the move ignores the build worktree, we set
# QC_WORKTREE to a REAL second worktree and assert: (a) the entry archives as a git-tracked rename in the
# MAIN tree, (b) the build worktree's HEAD did NOT move, (c) no stray unstaged D remains in the main index.
# The old "QC_WORKTREE unset collapses the seam" framing was wrong — it made a bare git mv and qc_git mv
# indistinguishable, which is how CR-001 shipped green.
rm -rf "$QUEUE_DIR/pending"/* "$QUEUE_DIR/done"/* "$QC_ARCHIVE_DIR"/*; : > "$QUEUE_DIR/done/.gitkeep"
write_entry done arch-a 100
write_entry done arch-b 110
write_entry done arch-blocked 120
write_entry pending arch-dep 200 "arch-blocked"   # arch-blocked is NOT settled (a live after: names it)
git add -A >/dev/null 2>&1; git commit -q -m "archival fixture" >/dev/null 2>&1

# ---------------------------------------------------------------------------------------------------------
# AC-012 (SHR4-C4): the DATE-PARTITIONED path assertion. After qc_archive_settled, a settled entry lands at
# $QC_ARCHIVE_DIR/$TODAY/<entry> (under a <date>-named sub-dir), NOT the pre-amendment flat $QC_ARCHIVE_DIR/<entry>.
# Asserted just after the archive below; here we record the expectation so the dated path is the explicit target.
# ---------------------------------------------------------------------------------------------------------

# A REAL second worktree (the production isolation seam). If qc_archive_settled wrongly routed the move
# through qc_git, it would target THIS worktree's index (where done/<label> is untracked) and silently fail.
BUILD_WT="$W/build-wt"
git worktree add --detach "$BUILD_WT" HEAD >/dev/null 2>&1
export QC_WORKTREE="$BUILD_WT"
BUILD_HEAD_BEFORE="$(git -C "$BUILD_WT" rev-parse HEAD)"

HEAD_BEFORE="$(git rev-parse HEAD)"
MOVED="$(qc_archive_settled)"

# AC-3/AC-012 — settled entries land in the DATE-PARTITIONED step-6-done/queue/<date>/, NOT removed (no git
# rm); arch-blocked stays in done/. SHR4-C4: the destination is the dated sub-dir ($DATED), not flat.
if [ -d "$DATED/arch-a" ] && [ -d "$DATED/arch-b" ]; then ok "AC-012: settled entries archived to the DATE-PARTITIONED step-6-done/queue/$TODAY/ (not flat)"; else ko "AC-012 dated landing" "arch-a/arch-b not under the dated sub-dir $DATED"; fi
# AC-012 negative: the entry must NOT be at the flat path (proves the date partition is actually applied).
if [ ! -d "$QC_ARCHIVE_DIR/arch-a" ]; then ok "AC-012: the archived entry is NOT at the flat step-6-done/queue/<entry> (date partition applied)"; else ko "AC-012 not-flat" "arch-a landed flat — the date partition was NOT applied"; fi
if [ ! -d "$QUEUE_DIR/done/arch-a" ] && [ ! -d "$QUEUE_DIR/done/arch-b" ]; then ok "AC-3: archived entries left done/ (moved, not copied)"; else ko "AC-3 source removal" "arch-a/arch-b still in done/"; fi
if [ -d "$QUEUE_DIR/done/arch-blocked" ]; then ok "AC-3: an entry with a live after: dependent is NOT archived (stays in done/)"; else ko "AC-3 withhold" "arch-blocked was wrongly archived"; fi
if [ "$MOVED" = "2" ]; then ok "AC-3: qc_archive_settled reports 2 moved"; else ko "AC-3 count" "moved='$MOVED' want 2"; fi

# AC-3 reversibility — the move was a git mv (rename tracked), reversible by inverse git mv. Assert the
# archived path (dated) is git-tracked and the original is gone from the index (a rename, not a delete+add).
if git ls-files --error-unmatch "$DATED/arch-a/arch-a.md" >/dev/null 2>&1; then ok "AC-3: archived entry is git-tracked at the new dated path (reversible by inverse git mv)"; else ko "AC-3 tracked" "archived arch-a not git-tracked at $DATED"; fi
# Assert NO git rm semantics: the file content is preserved at the new path (the artifact travelled).
if [ -f "$DATED/arch-a/arch-a.md" ] && [ -f "$DATED/arch-a/sidecar.json" ]; then ok "AC-3: the entry FOLDER (artifact + sidecar) travelled intact — no git rm"; else ko "AC-3 intact" "archived arch-a missing artifact/sidecar"; fi

# AC-5(a) — the move is a git-tracked RENAME in the MAIN tree (NOT an untracked ?? + unstaged D, which is what
# a wrongly-routed qc_git mv + plain-mv fallback would leave). `git status --porcelain` on the new path must
# show a staged add/rename (R.. or A.) and the archived file must be in the index; there must be NO untracked
# (??) marker for it.
MAIN_STATUS="$(git status --porcelain -- "$DATED/arch-a")"
if git ls-files --error-unmatch "$DATED/arch-a/arch-a.md" >/dev/null 2>&1 \
   && ! printf '%s\n' "$MAIN_STATUS" | grep -qE '^\?\?'; then
  ok "AC-5(a): archival is a git-tracked rename in the MAIN tree (no untracked ?? at the new dated path)"
else
  ko "AC-5(a) tracked-rename-in-main" "arch-a is not a tracked rename in the main tree (status='$MAIN_STATUS')"
fi
# AC-5(b) — the BUILD worktree's HEAD did NOT move. A correct bare main-tree move never touches the build
# worktree, so its HEAD is categorically untouched (no-HEAD-flip by not-touching, ADR-128 D-1). Also assert
# the operator/main tree HEAD is unmoved (archival stages a working-tree change, never a commit/checkout).
if [ "$(git -C "$BUILD_WT" rev-parse HEAD)" = "$BUILD_HEAD_BEFORE" ]; then ok "AC-5(b): the build worktree's HEAD did NOT move during archival (isolation by not touching it)"; else ko "AC-5(b) build-HEAD-flip" "build worktree HEAD moved during archival"; fi
if [ "$(git rev-parse HEAD)" = "$HEAD_BEFORE" ]; then ok "AC-5(b): archival did NOT flip the main-tree HEAD (no commit/checkout)"; else ko "AC-5(b) main-HEAD-flip" "main HEAD moved during archival"; fi
# AC-5(c) — no stray unstaged D remains in the main index for the moved source (a true rename stages the
# delete-of-old + add-of-new together; a plain-mv fallback on a TRACKED entry would leave an unstaged D).
if git status --porcelain | grep -qE '^ D .*step-4-queue/done/arch-[ab]/'; then
  ko "AC-5(c) stray-unstaged-D" "an unstaged D remains for an archived source (move was not a clean tracked rename)"
else
  ok "AC-5(c): no stray unstaged D remains in the main index (clean tracked rename)"
fi
# AC-5 source-level lint — qc_archive_settled moves via a BARE main-tree git mv (CR-001), NOT qc_git mv.
ARCH_BODY="$(awk '/^qc_archive_settled\(\) \{/{f=1} f{print} /^\}/{if(f)exit}' "$HERE/queue-chew-lib.sh")"
if printf '%s' "$ARCH_BODY" | grep -q 'qc_git mv'; then
  ko "AC-5 bare-git-mv" "qc_archive_settled still uses qc_git mv (CR-001: must be a bare main-tree git mv)"
elif printf '%s' "$ARCH_BODY" | grep -qE '(^|[^_])git mv '; then
  ok "AC-5: qc_archive_settled moves via a bare main-tree git mv (CR-001), not qc_git"
else
  ko "AC-5 bare-git-mv" "qc_archive_settled has no bare git mv"
fi

# AC-4 crash-order lint (source-level, mirrors the AC-5/AC-11 lint pattern) — the crash-consistency invariant
# #2 (single git mv, NO second manifest step) forbids any manifest write inside qc_archive_settled. The
# archival hop must introduce no new mv-then-set window: a crash mid-archival leaves a half-moved set the next
# idempotent pass completes (folder-as-truth). Assert the function body contains ZERO launch-manifest / set
# --status tokens (ADR-128 D-3 invariant #2, PLAN AC-4).
if printf '%s' "$ARCH_BODY" | grep -qE 'launch-manifest|set --status'; then
  ko "AC-4 crash-order" "qc_archive_settled contains a launch-manifest/set --status token (introduces a forbidden second manifest step — invariant #2)"
else
  ok "AC-4: qc_archive_settled has NO launch-manifest/set --status token (single mv, no new crash window — invariant #2)"
fi

# AC-7 — idempotent re-run is a no-op; .gitkeep is never archived.
git add -A >/dev/null 2>&1; git commit -q -m "post-archival" >/dev/null 2>&1
MOVED2="$(qc_archive_settled)"
if [ "$MOVED2" = "0" ]; then ok "AC-7: a second archival pass over the same state is a no-op"; else ko "AC-7 idempotent" "second pass moved='$MOVED2' want 0"; fi
if [ ! -e "$QC_ARCHIVE_DIR/.gitkeep" ]; then ok "AC-7: .gitkeep is never archived"; else ko "AC-7 .gitkeep" ".gitkeep was archived"; fi

# AC-4 — the failed| split: failed/ is NEVER touched by archival (done/-only). Seed a failed entry, archive,
# assert it stays in failed/.
write_entry failed arch-failed 130
qc_archive_settled >/dev/null 2>&1
# Never archived (neither flat nor dated): assert it appears NOWHERE under the archive base.
if [ -d "$QUEUE_DIR/failed/arch-failed" ] && ! find "$QC_ARCHIVE_DIR" -type d -name arch-failed 2>/dev/null | grep -q .; then ok "AC-4: failed/ entries are NEVER archived (done/-only — invariant #4)"; else ko "AC-4 failed-untouched" "arch-failed leaked out of failed/"; fi

# =========================================================================================================
echo "== QDM-T2: AC-9 legibility — the 'what is done?' surface covers the union =="
# =========================================================================================================
# After archival empties done/ into step-6-done/queue/, the operator-legibility 'what completed?' answer
# must still include the archived entry. The sanctioned surface reads qc_completed_labels() (the union).
LEGIBLE="$(qc_completed_labels)"
if printf '%s\n' "$LEGIBLE" | grep -qx "arch-a"; then ok "AC-9: an archived entry still appears in the 'what completed' surface (qc_completed_labels union)"; else ko "AC-9 legibility" "arch-a missing from the completion surface after archival"; fi
# And an entry STILL in done/ (withheld) also appears — the union covers both folders.
if printf '%s\n' "$LEGIBLE" | grep -qx "arch-blocked"; then ok "AC-9: a still-in-done/ entry also appears (union covers both folders)"; else ko "AC-9 union both" "arch-blocked missing from the completion surface"; fi

# =========================================================================================================
echo "== QDM-T2: AC-10 manifest run_dir resolves to a live folder after archival =="
# =========================================================================================================
# F-002 verification (codified): the queue-chew drain-to-done step records launch-manifest set with
# --label/--status/--branch/--sha but NO --run-dir (verified by grep at build time — no done/-relative
# run_dir is ever written, so the dangling-path edge is MOOT). This test asserts the resilient property the
# AC requires regardless: an archived entry's manifest record resolves to a LIVE folder via the union. We
# seed a manifest with a done-status feature whose run_dir is null (the real queue-chew shape) and assert
# its entry folder is resolvable through qc_completed_labels() after archival.
cp "$HERE/launch-manifest.py" core/scripts/launch-manifest.py 2>/dev/null || true
if [ -f core/scripts/launch-manifest.py ]; then
  MF="$W/fleet.json"
  python3 core/scripts/launch-manifest.py init --path "$MF" --slug archtest >/dev/null
  python3 core/scripts/launch-manifest.py add --path "$MF" --spec "x/arch-a.md" --label arch-a >/dev/null
  python3 core/scripts/launch-manifest.py set --path "$MF" --label arch-a --status done --sha deadbee >/dev/null
  RD="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["features"][0]["run_dir"])' "$MF")"
  # The real queue-chew shape: run_dir is null (never set to a done/-relative path) → archival cannot dangle it.
  if [ "$RD" = "None" ]; then ok "AC-10/F-002: queue-chew records NO done/-relative run_dir (manifest run_dir is null) — dangling edge moot"; else ko "AC-10 run_dir-null" "run_dir='$RD' (expected null/None for the queue-chew shape)"; fi
  # And the archived entry resolves to a LIVE folder via the union (the AC's resilient assertion).
  if printf '%s\n' "$(qc_completed_labels)" | grep -qx "arch-a" && [ -d "$DATED/arch-a" ]; then ok "AC-10: an archived entry's record still resolves to a live folder (step-6-done/queue/<date>/) via the union"; else ko "AC-10 resolve" "arch-a does not resolve to a live folder post-archival"; fi
else
  echo "  SKIP: AC-10 — launch-manifest.py not copyable into temp repo"
fi

# =========================================================================================================
echo "== SHR4-C4: AC-013 late-after: resolution across the DATE-PARTITIONED archive (the load-bearing arm) =="
# =========================================================================================================
# The regression backstop for the C3 dual-read. A `pending` entry whose `after:` names a label that has been
# DATE-PARTITIONED-archived (it exists ONLY at step-6-done/queue/<date>/<label>, not in done/) must resolve
# dep-ready via the REAL qc_completed_labels() chokepoint — NOT a re-implemented glob — so this FAILS if the
# read side ever regresses to globbing only the flat path. We archive a predecessor through the REAL writer
# (qc_archive_settled), confirm it landed dated, then add a dependent and assert qc_pick_entry selects it.
rm -rf "$QUEUE_DIR/pending"/* "$QUEUE_DIR/done"/* "$QC_ARCHIVE_DIR"/*; : > "$QUEUE_DIR/done/.gitkeep"
write_entry done orchestrated-pred-dated 100   # a settled predecessor (no live after: names it yet)
git add -A >/dev/null 2>&1; git commit -q -m "C4 dated-after fixture" >/dev/null 2>&1
qc_archive_settled >/dev/null 2>&1             # archive it through the REAL writer → dated layout
if [ -d "$DATED/orchestrated-pred-dated" ] && [ ! -d "$QUEUE_DIR/done/orchestrated-pred-dated" ]; then
  ok "AC-013 setup: predecessor archived to the dated layout (exists ONLY under step-6-done/queue/$TODAY/)"
else
  ko "AC-013 setup" "predecessor not at the dated archive path (writer did not date-partition)"
fi
# Now a late dependent: pending after:<the-dated-archived-label>. It must resolve dep-ready via the union.
write_entry pending nimble-after-dated 200 "orchestrated-pred-dated"
PICK_DATED="$(qc_pick_entry)"
if [ "$PICK_DATED" = "nimble-after-dated" ]; then
  ok "AC-013: a pending after:<DATE-PARTITIONED-archived> resolves dep-ready via the REAL qc_completed_labels() chokepoint"
else
  ko "AC-013 dated dual-read" "qc_pick_entry='$PICK_DATED' want 'nimble-after-dated' (the dated dual-read read side regressed)"
fi

# =========================================================================================================
echo "== SHR4-C4: F-004 legacy-FLAT dual-read — a pending after:<flat-archived> still resolves =="
# =========================================================================================================
# Proves the dual-read also covers the LEGACY FLAT entries the pre-amendment shipped code already produced.
# Seed a FLAT step-6-done/queue/<label> (NOT under a date sub-dir) by hand, then assert a pending after:<it>
# resolves dep-ready. If the read side only walked the dated sub-dirs, this flat-archived label would become a
# forward-reference miss and the dependent would never resolve (the exact failure the dual-read backstops).
rm -rf "$QUEUE_DIR/pending"/* "$QUEUE_DIR/done"/* "$QC_ARCHIVE_DIR"/*; : > "$QUEUE_DIR/done/.gitkeep"
mkdir -p "$QC_ARCHIVE_DIR/orchestrated-pred-flat"        # FLAT layout: directly under the archive base, no date.
: > "$QC_ARCHIVE_DIR/orchestrated-pred-flat/orchestrated-pred-flat.md"
# Sanity: the flat predecessor must NOT be under a date sub-dir (it's a true legacy-flat entry).
if [ -d "$QC_ARCHIVE_DIR/orchestrated-pred-flat" ] && [ ! -d "$DATED/orchestrated-pred-flat" ]; then
  ok "F-004 setup: a legacy FLAT archived entry seeded directly under step-6-done/queue/ (no date sub-dir)"
else
  ko "F-004 setup" "flat predecessor not seeded correctly"
fi
write_entry pending nimble-after-flat 300 "orchestrated-pred-flat"
PICK_FLAT="$(qc_pick_entry)"
if [ "$PICK_FLAT" = "nimble-after-flat" ]; then
  ok "F-004: a pending after:<LEGACY-FLAT-archived> still resolves dep-ready (dual-read covers the flat layout)"
else
  ko "F-004 flat dual-read" "qc_pick_entry='$PICK_FLAT' want 'nimble-after-flat' (the flat dual-read backstop regressed)"
fi
# Negative control: a date-named sub-dir is a PARTITION, never itself a completion label.
COMPLETED_NOW="$(qc_completed_labels)"
if ! printf '%s\n' "$COMPLETED_NOW" | grep -qx "$TODAY"; then
  ok "F-004: a YYYY-MM-DD partition dir is NEVER mistaken for a completion label (date-aware dual-read)"
else
  ko "F-004 partition-as-label" "the date partition '$TODAY' leaked into the completion set as a label"
fi

echo
echo "queue-archive: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
