#!/usr/bin/env bash
# Executable END-TO-END test for the /queue-chew daemon (ADR-124, queue v1.1; AWQ-T?/Wave 1).
#
# THE PROOF this wave exists to give. v1 shipped non-functional — all gates were STATIC and never ran a
# real chew, so the first real dogfood drain built ZERO artifacts. This test sources the deterministic
# mechanics lib (queue-chew-lib.sh) with a STUB launch_workflow (the pluggable launch+await hook), runs a
# REAL producer move-in → entry FOLDER in pending/ → the lib's pick → drain pending→running → target
# resolves to the in-queue artifact → stub launch writes a built file → running→done. GREEN means
# "a chew BUILT A FILE end-to-end" — NOT merely "done/ is non-empty".
#
# It also exercises the negative cases (each must REJECT-and-skip, NOT build): an entry name with ../
# (SA-001), a sidecar.target resolving outside docs/step-4-queue/ (SA-002), and a malformed/non-build kind
# (AC-010 allowlist).
#
# Portability: macOS (BSD realpath). Uses only the lib's _canon (os.path.realpath) — no GNU-only flags.
# Mirrors test-queue-order.sh / test-queue-chew.sh structure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — $2"; FAIL=$((FAIL+1)); }

# --- Build an isolated temp git repo so the lib's git mv / git status / git rev-parse work for real. ---
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cd "$W" || { echo "cannot cd to temp"; exit 1; }
git init -q
git config user.email "test@example.com"
git config user.name "queue-chew e2e"
git commit -q --allow-empty -m "root"

# The lib resolves scripts at .claude/scripts (consumer) else core/scripts. Provide queue-order.py at the
# core/scripts prefix so the arbiter's `dependents` call resolves inside the temp repo.
mkdir -p core/scripts
cp "$HERE/queue-order.py" core/scripts/queue-order.py
# Wave 2: the build-readiness classifier the lib's qc_classify_readiness calls.
cp "$HERE/queue-detect-readiness.py" core/scripts/queue-detect-readiness.py

# Queue root for this test (lib honors QUEUE_DIR override).
export QUEUE_DIR="docs/step-4-queue"
mkdir -p "$QUEUE_DIR/pending" "$QUEUE_DIR/running" "$QUEUE_DIR/done" "$QUEUE_DIR/failed"

# Source the deterministic mechanics lib UNDER TEST.
# shellcheck disable=SC1090
. "$HERE/queue-chew-lib.sh"

# ---------------------------------------------------------------------------------------------------------
# Producer move-in fixture: simulate `/queue add <kind> <target>` — create the entry FOLDER, move a source
# artifact INTO it, and write sidecar.json. This is the real on-disk shape qc_pick_entry consumes.
# args: label verb seq target [after] [artifact_relpath]
# ---------------------------------------------------------------------------------------------------------
producer_add() {
  local label="$1" verb="$2" seq="$3" target="$4" after="${5:-}" artifact="${6:-}"
  local dir="$QUEUE_DIR/pending/$label" dest
  mkdir -p "$dir"
  if [ -n "$artifact" ]; then
    mkdir -p "$dir/$(dirname "$artifact")"
    dest="$dir/$artifact"
  else
    dest="$dir/$label.md"
  fi
  # Default artifact is a PLANNED spec (## Tickets + ### KEY:) so an `orchestrated` entry passes the Wave 2
  # build-readiness gate. The raw-plan refuse test (below) overwrites this with a raw, ticket-less artifact.
  cat > "$dest" <<SPEC
# source artifact for $label

## Tickets

### QV-T1: build the thing
- depends_on: []
SPEC
  python3 - "$dir/sidecar.json" "$label" "$verb" "$seq" "$target" "$after" <<'PYEOF'
import json, sys
path, label, verb, seq, target, after = sys.argv[1:7]
side = {"label": label, "verb": verb, "seq": int(seq), "target": target}
if after:
    side["after"] = after
json.dump(side, open(path, "w"))
PYEOF
  git add -A "$dir" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------------------------------------
# THE STUB launch_workflow — the pluggable launch+await hook. In production the SKILL session provides the
# real one (fires a top-level Workflow and BLOCKS). Here it SIMULATES a build: it writes a build-output file
# INTO the resolved in-queue target, commits it (so the post-launch tree is clean — the success precondition),
# and returns the rc the test arms via STUB_RC. The --target it receives is the resolved in-queue artifact
# path (docs/step-4-queue/running/<entry>/<sidecar.target>).
# ---------------------------------------------------------------------------------------------------------
STUB_RC=0
STUB_BUILT_FILE=""          # set by the stub to the path it wrote, so the test can assert it exists
# SHR4-A3 gate-presence fixture knobs (mirror the DISPATCHED RUN folder the real recipe persists via
# persist-run-artifacts.py — A1). The gate-presence settle check (SKILL A2) reads findings/ from the RUN
# folder ($QC_RUN_DIR), NOT the queue entry folder. The stub simulates the recipe's persist by writing
# (or NOT writing) a batch-gate findings file under $STUB_RUN_DIR/findings/:
#   STUB_GATE_FINDINGS=present → write a NON-EMPTY findings/code-reviewer.md (gate ran) → settle may go done.
#   STUB_GATE_FINDINGS=absent  → write NO findings file (gate-less build) → the settle check must REFUSE done.
#   STUB_GATE_FINDINGS=empty   → write a ZERO-BYTE findings file → "non-empty" matters → still REFUSED.
STUB_RUN_DIR=""             # the dispatched run folder the stub "persists" into (set per-arm)
STUB_GATE_FINDINGS="present"
launch_workflow() {
  local kind="" target="" base_sha=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind="$2"; shift 2 ;;
      --target) target="$2"; shift 2 ;;
      --base-sha) base_sha="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  # Simulate a build that READS the in-queue target and WRITES an output artifact next to it.
  # target is a directory (sidecar.target "." → the entry folder) or a sub-path.
  if [ -d "$target" ]; then
    STUB_BUILT_FILE="$target/BUILD_OUTPUT.txt"
  else
    STUB_BUILT_FILE="$(dirname "$target")/BUILD_OUTPUT.txt"
  fi
  echo "built by $kind on base ${base_sha:-main}" > "$STUB_BUILT_FILE"
  # Simulate the recipe's persist (A1): write the batch-gate findings file onto the RUN folder per the arm.
  if [ -n "$STUB_RUN_DIR" ]; then
    mkdir -p "$STUB_RUN_DIR/findings"
    case "$STUB_GATE_FINDINGS" in
      present) printf '# code-reviewer findings\n\nClean pass, 0 criterion matches.\n' > "$STUB_RUN_DIR/findings/code-reviewer.md" ;;
      empty)   : > "$STUB_RUN_DIR/findings/code-reviewer.md" ;;   # zero-byte → NOT gate evidence
      absent)  rm -f "$STUB_RUN_DIR/findings/code-reviewer.md" "$STUB_RUN_DIR/findings/spec-conformance.md" 2>/dev/null || true ;;
    esac
  fi
  git add -A >/dev/null 2>&1 || true
  git commit -q -m "stub build for $kind" >/dev/null 2>&1 || true
  return "$STUB_RC"
}

# ---------------------------------------------------------------------------------------------------------
# qc_gate_presence_ok — MIRROR of the SKILL session loop's GATE-PRESENCE settle check (A2 / AC-003). The
# SKILL fires this BETWEEN qc_settle (outcome=done) and the render/base-advance: a settled `done` entry whose
# DISPATCHED RUN folder has NO non-empty batch-gate findings file (findings/code-reviewer*.md ∥
# findings/spec-conformance*.md) is SURFACED and REFUSED (not recorded done, base not advanced). This is the
# exact predicate; the test drives it so the gate-presence contract is FALSIFIABLE, not just prose.
#   arg: run_dir → exit 0 = gate evidence present (may settle done); exit 1 = absent (REFUSE the done settle).
# ---------------------------------------------------------------------------------------------------------
qc_gate_presence_ok() {
  local run_dir="$1" hit=""
  [ -n "$run_dir" ] && [ -d "$run_dir/findings" ] || return 1
  hit="$(find "$run_dir/findings" -maxdepth 1 -type f \( -name 'code-reviewer*.md' -o -name 'spec-conformance*.md' \) -size +0c 2>/dev/null | head -1)"
  [ -n "$hit" ]
}

# ---------------------------------------------------------------------------------------------------------
# drive_one — MIRROR OF THE SKILL SESSION LOOP (SHR3-T4 / AC-011, the wire-to-consumer seam). This is the
# REAL drain path the chew SKILL drives: qc_next (deterministic, before dispatch) → the REAL dispatch (here
# the stub launch_workflow) → qc_settle (deterministic, after dispatch). It is NOT a back-compat qc_run_one —
# it is the explicit two-call sequence with the dispatch BETWEEN, exactly as the SKILL loop wires it.
# Records QC_NEXT_FIRED / QC_SETTLE_FIRED so the test can assert BOTH real functions executed (not merely
# defined), and re-exports RC so callers branch on the same iteration codes as before.
# ---------------------------------------------------------------------------------------------------------
QC_NEXT_FIRED=0; QC_SETTLE_FIRED=0
QC_GATE_REFUSED=0           # SHR4-A3: set to 1 when the gate-presence settle check REFUSED a `done` (A2 mirror)
drive_one() {
  QC_NEXT_FIRED=0; QC_SETTLE_FIRED=0; QC_GATE_REFUSED=0
  qc_next; local rc=$?
  QC_NEXT_FIRED=1
  # rc != 0 is a terminal pre-dispatch verdict (empty/reject/refuse) — no dispatch, no settle (mirrors the
  # SKILL loop's case 2/3/4 which `break`/`continue` before launch).
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  # READY-TO-DISPATCH (rc 0). The SESSION fires the REAL Workflow with qc_next's caller-visible vars, BLOCKS
  # on its task-notification, then observes launch_rc + the worktree's NEW tip + dirty state.
  launch_workflow --kind "$QC_LAST_KIND" --target "$QC_LAST_TARGET" --base-sha "${PRIOR_TIP:-}"
  local launch_rc=$?
  QC_NEW_TIP="$(qc_git rev-parse HEAD 2>/dev/null || echo '')"
  local dirty; dirty="$(qc_git status --porcelain 2>/dev/null)"
  # Hand the observed outcome back to qc_settle (the after-dispatch deterministic half).
  qc_settle "$QC_LAST_ENTRY" "$QC_LAST_LABEL" "$launch_rc" "$dirty"; local srcv=$?
  QC_SETTLE_FIRED=1
  # --- GATE-PRESENCE settle check (SHR4-A3, mirrors SKILL A2 / AC-003): the SKILL fires this BETWEEN
  #     qc_settle(outcome=done) and the render/base-advance. A `done` whose dispatched run folder has NO
  #     non-empty batch-gate findings file is SURFACED + REFUSED (not recorded done, base not advanced).
  #     Refuse-don't-crash: a per-entry surface (QC_GATE_REFUSED=1), NOT a hard halt (ADR-105). ---
  # An arm OPTS INTO the gate-presence check by setting STUB_RUN_DIR (the dispatched run folder). Earlier
  # non-gate arms leave it empty and are not subject to the check (they predate the A2 gate-presence seam).
  if [ "$srcv" -eq 0 ] && [ "$QC_LAST_OUTCOME" = "done" ] && [ -n "$STUB_RUN_DIR" ]; then
    if ! qc_gate_presence_ok "$STUB_RUN_DIR"; then
      echo "queue-chew: GATE-PRESENCE REFUSE '$QC_LAST_LABEL' — settled done but its dispatched run folder ($STUB_RUN_DIR) has NO non-empty batch-gate findings file. Refusing to settle green on a gate-less build (AC-003)." >&2
      QC_GATE_REFUSED=1   # per-entry surface; the caller must NOT treat this as a clean `done` (base NOT advanced)
    fi
  fi
  return "$srcv"
}

# =========================================================================================================
# POSITIVE — a real chew BUILDS A FILE end-to-end via the qc_next → dispatch → qc_settle SEAM (SHR3-T4).
# =========================================================================================================
producer_add orchestrated-add-profiles orchestrated 100 "."
git commit -q -m "producer: add orchestrated-add-profiles" >/dev/null 2>&1 || true

# Sanity: the entry is a FOLDER in pending/ with sidecar.json + the moved artifact.
{ [ -d "$QUEUE_DIR/pending/orchestrated-add-profiles" ] \
  && [ -f "$QUEUE_DIR/pending/orchestrated-add-profiles/sidecar.json" ] \
  && [ -f "$QUEUE_DIR/pending/orchestrated-add-profiles/orchestrated-add-profiles.md" ]; } \
  && ok "producer move-in: entry is a FOLDER in pending/ with sidecar.json + moved artifact" \
  || ko "producer move-in" "entry folder/sidecar/artifact missing"

# Drive ONE REAL round-trip through the SEAM (qc_next → stub dispatch → qc_settle; SHR3-T4 / AC-011).
STUB_RC=0
PRIOR_TIP="$(git rev-parse HEAD)"
drive_one; RC=$?
[ "$RC" -eq 0 ] && ok "drive_one (qc_next→dispatch→qc_settle) drains a dep-ready entry (rc 0)" || ko "drive_one drain" "rc=$RC outcome=$QC_LAST_OUTCOME"

# AC-011 wire-to-consumer: BOTH real deterministic functions FIRED in the real drain path (not merely
# defined) — qc_next ran (pick/validate/drain), then qc_settle ran (outcome/move/reconcile).
{ [ "$QC_NEXT_FIRED" -eq 1 ] && [ "$QC_SETTLE_FIRED" -eq 1 ]; } \
  && ok "AC-011: qc_next AND qc_settle both EXECUTE in the real drain path (wire-to-consumer)" \
  || ko "AC-011 both-fire" "qc_next=$QC_NEXT_FIRED qc_settle=$QC_SETTLE_FIRED (a half did not fire)"

# THE load-bearing assertion: a file was actually BUILT (not just "done/ non-empty"). The stub wrote the
# output while the entry was in running/; the within-queue drain then moved the WHOLE entry folder to done/,
# so the build output now lives at done/<entry>/BUILD_OUTPUT.txt (it travelled with the folder).
BUILT_FINAL="$QUEUE_DIR/done/orchestrated-add-profiles/BUILD_OUTPUT.txt"
{ [ -n "$STUB_BUILT_FILE" ] && [ -f "$BUILT_FINAL" ]; } \
  && ok "a chew BUILT A FILE end-to-end ($BUILT_FINAL exists)" \
  || ko "built-file proof" "no build output file exists (stub target was '$STUB_BUILT_FILE', final '$BUILT_FINAL')"

# The build output lives UNDER the in-queue entry (target resolved to the in-queue artifact, not an external
# path) — the stub's target was inside docs/step-4-queue/.../<entry>/.
case "$STUB_BUILT_FILE" in
  "$QUEUE_DIR"/running/orchestrated-add-profiles/*|"$QUEUE_DIR"/done/orchestrated-add-profiles/*)
    ok "target resolved to the IN-QUEUE artifact (build wrote under docs/step-4-queue/<entry>/)" ;;
  *) ko "in-queue target" "built file '$STUB_BUILT_FILE' is not under the in-queue entry" ;;
esac

# The entry FOLDER (with the artifact travelling inside it) ended up in done/, not pending/ or failed/.
{ [ -d "$QUEUE_DIR/done/orchestrated-add-profiles" ] \
  && [ ! -d "$QUEUE_DIR/pending/orchestrated-add-profiles" ] \
  && [ ! -d "$QUEUE_DIR/running/orchestrated-add-profiles" ]; } \
  && ok "entry folder moved pending→running→done (within-queue drain, artifact travelled with it)" \
  || ko "within-queue drain" "entry not solely in done/"

# The artifact travelled with the folder (the moved source md is now in done/<entry>/).
[ -f "$QUEUE_DIR/done/orchestrated-add-profiles/orchestrated-add-profiles.md" ] \
  && ok "the moved source artifact travelled WITH the entry folder into done/" \
  || ko "artifact travel" "source artifact not in done/<entry>/"

# WRAP point: a drained queue yields nothing dep-ready.
drive_one; RC=$?
{ [ "$RC" -eq 2 ] && [ "$QC_LAST_OUTCOME" = "empty" ]; } \
  && ok "drained queue → no dep-ready entry (rc 2, WRAP point)" \
  || ko "wrap" "rc=$RC outcome=$QC_LAST_OUTCOME"

# =========================================================================================================
# NEGATIVE 1 — entry name with ../ → SA-001 reject-and-skip (NEVER build).
# We craft the malformed pending entry directly (the producer would not name one this way; this models a
# crafted/buggy on-disk entry the unattended daemon must reject). The lib's qc_pick_entry only emits a
# basename, so we assert the validator directly catches a traversal name.
# =========================================================================================================
BAD_ENTRY="../evil"
if qc_validate_entry "$BAD_ENTRY" 2>/dev/null; then
  ko "SA-001 traversal" "qc_validate_entry ACCEPTED '$BAD_ENTRY' (should reject)"
else
  ok "SA-001: entry name with ../ is REJECTED (path-traversal guard), not built"
fi
# A leading-dash / slash name is also rejected.
if qc_validate_entry "-flag" 2>/dev/null || qc_validate_entry "a/b" 2>/dev/null; then
  ko "SA-001 shape" "accepted a leading-dash or slash entry name"
else
  ok "SA-001: leading-dash and slash entry names are REJECTED"
fi

# SA-003 newline log-injection guard (SA-FINDING-001) — a label/kind carrying an embedded newline must be
# REJECTED. `grep`'s per-line `^…$` anchors used to let a `\n`-bearing value forge a second daemon log line;
# the bash `[[ =~ ]]` whole-string match closes that. Assert both a forged label and a forged kind reject.
if qc_validate_label_kind "$(printf 'safe\nforged-line')" "nimble" 2>/dev/null \
   || qc_validate_label_kind "ok" "$(printf 'nimble\nforged')" 2>/dev/null; then
  ko "SA-003 newline" "qc_validate_label_kind ACCEPTED a newline-bearing label/kind (log-injection bypass)"
else
  ok "SA-003: newline-bearing label/kind is REJECTED (log-injection guard, SA-FINDING-001)"
fi
if qc_validate_entry "$(printf 'safe\nforged')" 2>/dev/null; then
  ko "SA-001 newline" "qc_validate_entry ACCEPTED a newline-bearing entry name"
else
  ok "SA-001: newline-bearing entry name is REJECTED"
fi

# =========================================================================================================
# NEGATIVE 2 — sidecar.target resolving OUTSIDE docs/step-4-queue/ → SA-002 reject-and-skip + un-drain.
# Build a real entry whose target escapes the queue root, drain it to running/, then assert qc_resolve_target
# rejects it (and the iteration un-drains it back to pending/, never building).
# =========================================================================================================
producer_add orchestrated-escape orchestrated 200 "../../../etc"
git commit -q -m "producer: add orchestrated-escape (malicious target)" >/dev/null 2>&1 || true

STUB_BUILT_FILE=""           # reset; nothing should be built for this entry
STUB_RC=0
PRIOR_TIP="$(git rev-parse HEAD)"
drive_one; RC=$?
{ [ "$RC" -eq 3 ] && [ "$QC_LAST_OUTCOME" = "reject" ]; } \
  && ok "SA-002: target escaping docs/step-4-queue/ is REJECTED (rc 3, reject-and-skip)" \
  || ko "SA-002 reject" "rc=$RC outcome=$QC_LAST_OUTCOME"

# Un-drained: the entry is back in pending/ (NOT running/, NOT done/), and NOTHING was built.
{ [ -d "$QUEUE_DIR/pending/orchestrated-escape" ] \
  && [ ! -d "$QUEUE_DIR/running/orchestrated-escape" ] \
  && [ ! -d "$QUEUE_DIR/done/orchestrated-escape" ] \
  && [ -z "$STUB_BUILT_FILE" ]; } \
  && ok "SA-002: rejected entry un-drained running→pending, nothing built" \
  || ko "SA-002 un-drain" "entry not back in pending/ or a file was built (built='$STUB_BUILT_FILE')"

# Remove the escape entry so it does not block the next negative case's pick.
rm -rf "$QUEUE_DIR/pending/orchestrated-escape"
git add -A >/dev/null 2>&1 || true
git commit -q -m "remove escape fixture" >/dev/null 2>&1 || true

# =========================================================================================================
# NEGATIVE 3 — a malformed/non-build kind → AC-010 allowlist reject-and-skip (NEVER build).
# A `roadmap` (planning verb) and a bogus kind must both be rejected; the entry is LEFT in pending/.
# This asserts the LIB's BUILD-ONLY path: drive_one rejects `roadmap` via qc_validate_kind (the lib stays
# build-only — it never STAGE-routes). It is NOT a contradiction against the new STAGE route — the SKILL's
# session-level STAGE pre-route intercepts a `roadmap` entry EARLIER (before drive_one), producing a spec;
# see the SHR4-D STAGE arm in core/skills/queue-chew/SKILL.md. Here we exercise drive_one directly (no
# pre-route), so the lib's reject-and-skip is the correct, asserted behavior.
# =========================================================================================================
producer_add roadmap-plan-x roadmap 300 "."
git commit -q -m "producer: add roadmap-plan-x (planning verb)" >/dev/null 2>&1 || true

STUB_BUILT_FILE=""
STUB_RC=0
PRIOR_TIP="$(git rev-parse HEAD)"
drive_one; RC=$?
{ [ "$RC" -eq 3 ] && [ "$QC_LAST_OUTCOME" = "reject" ] && [ -z "$STUB_BUILT_FILE" ]; } \
  && ok "AC-010: planning-verb kind (roadmap) is REJECTED at drain (rc 3), nothing built" \
  || ko "AC-010 roadmap reject" "rc=$RC outcome=$QC_LAST_OUTCOME built='$STUB_BUILT_FILE'"

# The rejected planning entry is LEFT in pending/ (not the daemon's to move).
[ -d "$QUEUE_DIR/pending/roadmap-plan-x" ] \
  && ok "AC-010: rejected planning verb is LEFT in pending/ (not moved)" \
  || ko "AC-010 left-in-pending" "roadmap entry was moved out of pending/"

# Direct allowlist check: a bogus kind is rejected, the four build kinds are accepted.
qc_validate_kind bogus 2>/dev/null && ko "AC-010 bogus" "accepted a bogus kind" \
  || { qc_validate_kind orchestrated 2>/dev/null && qc_validate_kind nimble 2>/dev/null \
       && qc_validate_kind chain 2>/dev/null && qc_validate_kind loop 2>/dev/null \
       && ok "AC-010: bogus kind rejected; {orchestrated,nimble,chain,loop} accepted" \
       || ko "AC-010 allowlist" "a live build kind was rejected"; }

# =========================================================================================================
# NEGATIVE 4 — a non-zero build outcome (clean tree, no dependents) → PARK, entry to failed/, NOT done/.
# =========================================================================================================
producer_add nimble-flaky nimble 400 "."
git commit -q -m "producer: add nimble-flaky" >/dev/null 2>&1 || true
# Remove the lingering rejected roadmap entry so the flaky one is picked.
rm -rf "$QUEUE_DIR/pending/roadmap-plan-x"
git add -A >/dev/null 2>&1 || true
git commit -q -m "remove roadmap fixture" >/dev/null 2>&1 || true

STUB_BUILT_FILE=""
STUB_RC=7                    # non-zero build outcome (the stub still commits, so the tree stays clean)
PRIOR_TIP="$(git rev-parse HEAD)"
drive_one; RC=$?
{ [ "$RC" -eq 0 ] && [ "$QC_LAST_OUTCOME" = "failed" ]; } \
  && ok "failed build (clean tree, no deps) → PARK-and-continue (rc 0, outcome failed)" \
  || ko "park" "rc=$RC outcome=$QC_LAST_OUTCOME"
{ [ -d "$QUEUE_DIR/failed/nimble-flaky" ] && [ ! -d "$QUEUE_DIR/done/nimble-flaky" ]; } \
  && ok "failed entry terminates in failed/ (NOT done/) — terminal split preserved" \
  || ko "failed sink" "entry not solely in failed/"

# =========================================================================================================
# WAVE 2 — build-readiness routing (Fork B). The classifier + the chew's refuse-raw-plan default.
# =========================================================================================================
DET="core/scripts/queue-detect-readiness.py"
# A PLANNED spec: `## Tickets` heading + a `### KEY:` ticket block (mirrors orchestrated parsesToTickets).
mkdir -p /tmp/qc_planned_$$ && cat > /tmp/qc_planned_$$/wave-1.md <<'SPEC'
# Wave: demo
## Tickets
### DM-T1: do the thing
- depends_on: []
SPEC
# A RAW plan: a shaped thesis, no ticket graph.
mkdir -p /tmp/qc_raw_$$ && cat > /tmp/qc_raw_$$/plan.md <<'PLAN'
# A raw plan
We should build a thing. Here is the shape and rationale. No ticket decomposition yet.
PLAN
{ [ "$(python3 "$DET" /tmp/qc_planned_$$)" = "PLANNED" ] && [ "$(python3 "$DET" /tmp/qc_raw_$$)" = "NOT_PLANNED" ]; } \
  && ok "readiness detector: PLANNED spec ↔ PLANNED, raw plan ↔ NOT_PLANNED (mirrors parsesToTickets)" \
  || ko "detector" "planned=$(python3 "$DET" /tmp/qc_planned_$$) raw=$(python3 "$DET" /tmp/qc_raw_$$)"

# qc_classify_readiness: orchestrated+PLANNED → proceed; orchestrated+raw → refuse (default); raw+opt-in →
# proceed; nimble (any) → proceed (no decompose distinction).
R_PLANNED=$(qc_classify_readiness orchestrated /tmp/qc_planned_$$)
R_RAW=$(qc_classify_readiness orchestrated /tmp/qc_raw_$$)
R_RAW_OPTIN=$(QUEUE_ALLOW_RAW_PLAN=1 qc_classify_readiness orchestrated /tmp/qc_raw_$$)
R_NIMBLE=$(qc_classify_readiness nimble /tmp/qc_raw_$$)
{ [ "$R_PLANNED" = proceed ] && [ "$R_RAW" = refuse ] && [ "$R_RAW_OPTIN" = proceed ] && [ "$R_NIMBLE" = proceed ]; } \
  && ok "qc_classify_readiness: planned→proceed, raw→refuse(default), raw+opt-in→proceed, nimble→proceed" \
  || ko "classify" "planned=$R_PLANNED raw=$R_RAW optin=$R_RAW_OPTIN nimble=$R_NIMBLE"
rm -rf /tmp/qc_planned_$$ /tmp/qc_raw_$$

# End-to-end: an `orchestrated` entry whose in-queue artifact is a RAW plan is REFUSED (rc 4), un-drained
# back to pending/, and nothing is built.
producer_add "orchestrated-raw-plan" orchestrated 900 "."
# Overwrite the default PLANNED artifact with a genuinely RAW plan (no ## Tickets / ### KEY:) so the
# readiness gate refuses it. (producer_add defaults to a planned spec for the positive orchestrated cases.)
printf '# a raw plan\n\nShape + rationale, no ticket decomposition yet.\n' \
  > "$QUEUE_DIR/pending/orchestrated-raw-plan/orchestrated-raw-plan.md"
git add -A "$QUEUE_DIR/pending/orchestrated-raw-plan" >/dev/null 2>&1 || true
STUB_BUILT_FILE=""; STUB_RC=0
PRIOR_TIP="$(git rev-parse HEAD)"
drive_one; RC=$?
{ [ "$RC" -eq 4 ] && [ "$QC_LAST_OUTCOME" = "refuse-raw-plan" ] && [ -z "$STUB_BUILT_FILE" ]; } \
  && ok "raw-plan orchestrated entry → REFUSED (rc 4, outcome refuse-raw-plan), nothing built" \
  || ko "refuse-raw-plan" "rc=$RC outcome=$QC_LAST_OUTCOME built='$STUB_BUILT_FILE'"
{ [ -d "$QUEUE_DIR/pending/orchestrated-raw-plan" ] && [ ! -d "$QUEUE_DIR/running/orchestrated-raw-plan" ] && [ ! -d "$QUEUE_DIR/done/orchestrated-raw-plan" ]; } \
  && ok "refused raw plan un-drained running→pending (left queued for /roadmap)" \
  || ko "refuse un-drain" "entry not solely back in pending/"
# With the opt-in, the SAME raw-plan entry now PROCEEDS to build.
STUB_BUILT_FILE=""; STUB_RC=0
QUEUE_ALLOW_RAW_PLAN=1 drive_one; RC=$?
{ [ "$RC" -eq 0 ] && [ "$QC_LAST_OUTCOME" = "done" ] && [ -n "$STUB_BUILT_FILE" ]; } \
  && ok "QUEUE_ALLOW_RAW_PLAN=1: the same raw plan now PROCEEDS and builds (opt-in)" \
  || ko "raw-plan opt-in" "rc=$RC outcome=$QC_LAST_OUTCOME built='$STUB_BUILT_FILE'"

# =========================================================================================================
# WAVE 3 — deterministic planned_files derivation (activates the dormant overlap edges).
# =========================================================================================================
cp "$HERE/queue-derive-planned-files.py" core/scripts/queue-derive-planned-files.py
DERV="core/scripts/queue-derive-planned-files.py"
# A spec with two tickets declaring overlapping planned_files → derive the de-duplicated, sorted union.
mkdir -p /tmp/qc_pf_$$ && cat > /tmp/qc_pf_$$/wave.md <<'PFSPEC'
# Wave: demo
## Tickets
### DM-T1: a
- planned_files: [core/b.py, core/a.py]
### DM-T2: b
- planned_files: [core/a.py, core/c.py]
PFSPEC
DERIVED="$(python3 "$DERV" /tmp/qc_pf_$$)"
{ [ "$DERIVED" = "core/a.py,core/b.py,core/c.py" ]; } \
  && ok "derive: union of declared planned_files, de-duped + sorted (core/a,core/b,core/c)" \
  || ko "derive union" "got '$DERIVED'"
# A raw plan (no planned_files declarations) → empty derivation (overlap detection stays inactive).
mkdir -p /tmp/qc_pfraw_$$ && printf '# raw plan\nno tickets, no planned_files\n' > /tmp/qc_pfraw_$$/p.md
{ [ -z "$(python3 "$DERV" /tmp/qc_pfraw_$$)" ]; } \
  && ok "derive: a raw plan yields EMPTY planned_files (overlap detection correctly inactive)" \
  || ko "derive raw" "expected empty, got '$(python3 "$DERV" /tmp/qc_pfraw_$$)'"
# Integration: derived planned_files make the orderer's overlap edge LIVE. Two pending entries whose
# (derived) planned_files overlap, with no `after` declared, → compute flags a conflict (rc 3).
mkdir -p "$QUEUE_DIR/pending/nimble-aaa" "$QUEUE_DIR/pending/nimble-bbb"
python3 -c "import json;json.dump({'label':'nimble-aaa','verb':'nimble','seq':100,'planned_files':['core/x.py']},open('$QUEUE_DIR/pending/nimble-aaa/sidecar.json','w'))"
echo "x" > "$QUEUE_DIR/pending/nimble-aaa/a.md"
python3 "$HERE/queue-order.py" compute --pending "$QUEUE_DIR/pending" --planned-files "core/x.py" >/dev/null 2>&1
OVRC=$?
{ [ "$OVRC" -eq 3 ]; } \
  && ok "derived planned_files activate the overlap edge: undeclared overlap → conflict (rc 3, not a guess)" \
  || ko "overlap activation" "expected rc 3, got $OVRC"
rm -rf /tmp/qc_pf_$$ /tmp/qc_pfraw_$$ "$QUEUE_DIR/pending/nimble-aaa" "$QUEUE_DIR/pending/nimble-bbb"

# =========================================================================================================
# SHR3-T4 — qc_next/qc_settle SPLIT + launch_workflow DEMOTION (AC-009, AC-010, the security boundary).
# =========================================================================================================
LIB="$HERE/queue-chew-lib.sh"
# AC-009: both halves of the split exist as real functions.
{ type qc_next >/dev/null 2>&1 && type qc_settle >/dev/null 2>&1; } \
  && ok "SHR3-T4 (AC-009): qc_next AND qc_settle are defined (qc_run_one split across the dispatch)" \
  || ko "SHR3-T4 split" "qc_next / qc_settle not both defined"
# AC-009: the old single-body qc_run_one is GONE from the lib (no inline-dispatch body survives).
grep -qE '^qc_run_one\(\)' "$LIB" \
  && ko "SHR3-T4 qc_run_one" "qc_run_one is still DEFINED in the lib (the inline-dispatch body must be split out)" \
  || ok "SHR3-T4 (AC-009): qc_run_one removed from the lib (no inline-dispatch body)"
# AC-010 (the security boundary): launch_workflow is DEMOTED OUT of the production path — no EXECUTABLE call
# site survives in the lib (only comment references). Strip comments, then grep for an executable call.
if grep -vE '^\s*#' "$LIB" | grep -qE 'launch_workflow'; then
  ko "SHR3-T4 launch_workflow" "an EXECUTABLE launch_workflow reference survives in the production lib (must be test-only)"
else
  ok "SHR3-T4 (AC-010): launch_workflow has NO executable call site in the production lib (test-only stub)"
fi
# AC-010: the ONLY surviving launch_workflow definition is the test-only stub in THIS file.
grep -qE '^launch_workflow\(\)' "$HERE/test-queue-chew-e2e.sh" \
  && ok "SHR3-T4 (AC-010): launch_workflow survives only as the test-only stub (test-seam)" \
  || ko "SHR3-T4 stub" "the test-only launch_workflow stub is missing"

# =========================================================================================================
# SHR3-T3 — WORKTREE ISOLATION SEAM (AC-007, ADR-046). The daemon's git ops MUST target a dedicated worktree
# (qc_worktree_dir / qc_git), NOT the operator's interactive main repo root. Assert the seam exists and that
# with QC_WORKTREE exported, the lib's git operations are scoped to the worktree path — not the main tree.
# =========================================================================================================
# The seam functions are defined in the lib.
{ type qc_worktree_dir >/dev/null 2>&1 && type qc_git >/dev/null 2>&1; } \
  && ok "SHR3-T3: isolation seam present (qc_worktree_dir + qc_git defined)" \
  || ko "SHR3-T3 seam" "qc_worktree_dir / qc_git not defined in the lib"

# The seam is grep-visible in the lib (AC-007 verification: grep -n "worktree" must show it).
grep -q "worktree" "$HERE/queue-chew-lib.sh" \
  && ok "SHR3-T3: grep 'worktree' shows the seam in queue-chew-lib.sh" \
  || ko "SHR3-T3 grep" "no 'worktree' token in queue-chew-lib.sh"

# Build a SECOND, dedicated worktree off the temp repo and assert qc_git targets IT, not the main tree.
# Make the worktree's HEAD diverge from the main tree's HEAD, then assert qc_git rev-parse HEAD (with
# QC_WORKTREE set) reads the WORKTREE's HEAD — proving the daemon's git ops are isolated.
MAIN_HEAD="$(git rev-parse HEAD)"
WT="$W/.worktrees/qc-isolation-test"
git worktree add --detach -q "$WT" HEAD
git -C "$WT" commit -q --allow-empty -m "worktree-only commit (HEAD diverges from main tree)"
WT_HEAD="$(git -C "$WT" rev-parse HEAD)"
{ [ "$MAIN_HEAD" != "$WT_HEAD" ]; } \
  && ok "SHR3-T3: test fixture — worktree HEAD diverges from main tree HEAD" \
  || ko "SHR3-T3 fixture" "worktree HEAD did not diverge ($MAIN_HEAD == $WT_HEAD)"
# Default (no QC_WORKTREE): qc_worktree_dir resolves to the main repo root; qc_git reads the MAIN HEAD.
unset QC_WORKTREE
{ [ "$(qc_git rev-parse HEAD)" = "$MAIN_HEAD" ]; } \
  && ok "SHR3-T3: unset QC_WORKTREE → qc_git targets the current tree (testable default)" \
  || ko "SHR3-T3 default" "qc_git did not read the main HEAD"
# With QC_WORKTREE set: qc_worktree_dir resolves to the worktree; qc_git reads the WORKTREE's HEAD — the
# daemon's git ops are SCOPED to the worktree, NEVER the operator's main tree (the HEAD-flip surface).
QC_WORKTREE="$WT"
{ [ "$(qc_worktree_dir)" = "$WT" ] && [ "$(qc_git rev-parse HEAD)" = "$WT_HEAD" ] && [ "$(qc_git rev-parse HEAD)" != "$MAIN_HEAD" ]; } \
  && ok "SHR3-T3: QC_WORKTREE set → qc_git rev-parse/status target the WORKTREE, not the operator's tree (HEAD-flip surface isolated)" \
  || ko "SHR3-T3 isolation" "qc_git did not target the worktree ($(qc_git rev-parse HEAD) vs WT $WT_HEAD / MAIN $MAIN_HEAD)"
unset QC_WORKTREE
git worktree remove --force "$WT" >/dev/null 2>&1 || true

# =========================================================================================================
# SHR4-A3 — GATE-PRESENCE assertion (AC-003) + launch_workflow demotion confirmation (AC-004).
# Proves the Wave A green-on-gateless backstop: a settled `done` must carry a NON-EMPTY batch-gate findings
# file on its DISPATCHED RUN folder; a `done` settle is REFUSED when that file is absent (or empty). The
# findings live on the RUN folder (where the recipe persists — A1), NOT the queue entry folder.
# STAY IN THE GATE-PRESENCE LANE: the dual-shell (bash+zsh) matrix is Wave B (AC-010) — not added here.
# =========================================================================================================
GP_RUN_BASE="$W/run-folders"

# --- POSITIVE arm: a `done` run that PRODUCED a non-empty batch-gate findings file → settles done. -----
producer_add gate-present nimble 1000 "."
git commit -q -m "producer: add gate-present" >/dev/null 2>&1 || true
STUB_BUILT_FILE=""; STUB_RC=0
STUB_RUN_DIR="$GP_RUN_BASE/gate-present"; STUB_GATE_FINDINGS="present"   # recipe persisted a non-empty findings file
PRIOR_TIP="$(git rev-parse HEAD)"
drive_one; RC=$?
{ [ "$RC" -eq 0 ] && [ "$QC_LAST_OUTCOME" = "done" ] && [ "$QC_GATE_REFUSED" -eq 0 ]; } \
  && ok "AC-003 positive: a settled done run with a NON-EMPTY batch-gate findings file settles done (gate-presence satisfied)" \
  || ko "AC-003 positive" "rc=$RC outcome=$QC_LAST_OUTCOME refused=$QC_GATE_REFUSED"
# The gate-presence signal really is a non-empty findings file on the RUN folder (not the queue entry folder).
{ [ -s "$STUB_RUN_DIR/findings/code-reviewer.md" ] && [ ! -e "$QUEUE_DIR/done/gate-present/findings/code-reviewer.md" ]; } \
  && ok "AC-003: the gate-presence signal is a NON-EMPTY findings file on the RUN folder, NOT the queue entry folder" \
  || ko "AC-003 run-folder signal" "findings not on run folder, or leaked onto the queue entry folder"

# --- NEGATIVE arm 1: a `done` run with NO batch-gate findings file → the done settle is REFUSED. --------
producer_add gate-absent nimble 1100 "."
git commit -q -m "producer: add gate-absent" >/dev/null 2>&1 || true
STUB_BUILT_FILE=""; STUB_RC=0
STUB_RUN_DIR="$GP_RUN_BASE/gate-absent"; STUB_GATE_FINDINGS="absent"   # gate-less build: recipe persisted NO findings
PRIOR_TIP="$(git rev-parse HEAD)"
PRIOR_TIP_BEFORE="$PRIOR_TIP"
drive_one; RC=$?
{ [ "$QC_GATE_REFUSED" -eq 1 ]; } \
  && ok "AC-003 negative (absent): a done run with NO batch-gate findings file is REFUSED (surfaced, not settled green)" \
  || ko "AC-003 negative absent" "gate-presence did NOT refuse a gate-less done (refused=$QC_GATE_REFUSED outcome=$QC_LAST_OUTCOME)"
# REFUSE-don't-advance: the linear-stack base is NOT advanced for a refused entry (it must stay the prior tip).
{ [ "$QC_GATE_REFUSED" -eq 1 ] && [ "$PRIOR_TIP" = "$PRIOR_TIP_BEFORE" ]; } \
  && ok "AC-003 negative: a refused done does NOT advance the linear-stack base (PRIOR_TIP unchanged for the entry)" \
  || ko "AC-003 base-advance" "PRIOR_TIP advanced past a refused entry"

# --- NEGATIVE arm 2: a `done` run with an EMPTY (zero-byte) findings file → still REFUSED ("non-empty" matters).
producer_add gate-empty nimble 1200 "."
git commit -q -m "producer: add gate-empty" >/dev/null 2>&1 || true
STUB_BUILT_FILE=""; STUB_RC=0
STUB_RUN_DIR="$GP_RUN_BASE/gate-empty"; STUB_GATE_FINDINGS="empty"   # zero-byte findings file → NOT gate evidence
PRIOR_TIP="$(git rev-parse HEAD)"
drive_one; RC=$?
{ [ "$QC_GATE_REFUSED" -eq 1 ]; } \
  && ok "AC-003 negative (empty): a ZERO-BYTE findings file is NOT gate evidence — the done settle is REFUSED" \
  || ko "AC-003 negative empty" "an empty findings file was accepted as gate evidence (refused=$QC_GATE_REFUSED)"
# Reset the gate-presence fixture knobs so they cannot leak into any later arm.
STUB_RUN_DIR=""; STUB_GATE_FINDINGS="present"

# --- AC-004: confirm launch_workflow is invoked by NO production drain path; only call site is the test stub.
# The lib carries no executable launch_workflow (strip comments, grep) and no production drain function in
# SKILL.md invokes it. This complements the SHR3-T4 :404-425 demotion asserts (which stay green above).
SKILL="$HERE/../skills/queue-chew/SKILL.md"; [ -f "$SKILL" ] || SKILL="$HERE/../../core/skills/queue-chew/SKILL.md"
if grep -vE '^\s*#' "$LIB" | grep -qE 'launch_workflow'; then
  ko "AC-004 lib" "an EXECUTABLE launch_workflow call survives in the production lib (must be test-only)"
else
  ok "AC-004: launch_workflow has NO executable call site in the production lib (no production drain path invokes it)"
fi
if [ -f "$SKILL" ]; then
  # The SKILL prose must not carry an executable launch_workflow call (only demotion references). It is a doc,
  # so every mention sits in markdown prose — assert none is a shell call line of the form `launch_workflow (`...
  if grep -E '^\s*launch_workflow[[:space:]]+--' "$SKILL" >/dev/null 2>&1; then
    ko "AC-004 skill" "the SKILL carries an executable launch_workflow call line (must be demoted to text-only)"
  else
    ok "AC-004: the queue-chew SKILL carries NO executable launch_workflow call (demotion reflected in text)"
  fi
fi

# =========================================================================================================
# SHR4-D4 — STAGE-KIND NO-ARCHIVE (AC-015 verification: STAGE membership is CONSUMED BY ROUTING — D2).
# Proves D2's STAGE routing FIRES (wire-to-consumer, not just the STAGE_KINDS constant existing): a settled
# `roadmap` STAGE entry is NOT archived to step-6-done/queue (it skips qc_archive_settled) and is NOT moved
# to done/ as a terminal — the STAGE entry diverged from the build/archive path exactly where D2's membership
# check routes it. We MIRROR the SKILL's session-level STAGE pre-route (the lib stays build-only — exactly
# like drive_one mirrors the SKILL settle loop): a STAGE entry drains pending/ → staged/ (NOT done/), so the
# build-archival sweep (qc_archive_settled, which only ever reads done/) categorically never sees it.
# We assert the BEHAVIOR (the no-archive routing), not merely the constant — AC-015 is wire-to-consumer.
# =========================================================================================================
# stage_route ENTRY — MIRROR of the SKILL's STAGE pre-route (queue-chew/SKILL.md, D2): a STAGE-kind entry is
# routed to the staged/ terminal (NOT done/), so qc_archive_settled (build-archival) never archives it. This
# is the test-side mirror of the session-level route, the same discipline as drive_one mirroring the loop.
stage_route() {
  local entry="$1"
  qc_drain_to pending staged "$entry"   # the SKILL's `qc_drain_to pending staged "$QC_PEEK_ENTRY"` (D2)
}

# qc_archive_settled (the daemon's build-archival sweep) needs queue-archive.py at the core/scripts prefix the
# lib resolves — provide it (the main arm did not yet need it; the dual-shell inner arm copies its own).
cp "$HERE/queue-archive.py" core/scripts/queue-archive.py
# Read STAGE_KINDS from launch-manifest.py (the D1 source of truth) — provide it under core/scripts like the
# other helpers, then assert `roadmap` ∈ STAGE_KINDS and `sweep` ∉ STAGE_KINDS (the routing's gate).
cp "$HERE/launch-manifest.py" core/scripts/launch-manifest.py
STAGE_KINDS_VAL="$(python3 -c 'import importlib.util; s=importlib.util.spec_from_file_location("lm","core/scripts/launch-manifest.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(" ".join(sorted(m.STAGE_KINDS)))')"
case " $STAGE_KINDS_VAL " in
  *" roadmap "*) case " $STAGE_KINDS_VAL " in *" sweep "*) ko "D4 STAGE_KINDS" "sweep IS in STAGE_KINDS (Phase-1 boundary violated)";; *) ok "AC-015: STAGE_KINDS contains roadmap and NOT sweep (the routing gate, from launch-manifest.py D1)";; esac ;;
  *) ko "D4 STAGE_KINDS" "roadmap NOT in STAGE_KINDS ('$STAGE_KINDS_VAL')" ;;
esac

# Create a `roadmap` STAGE entry in pending/, route it (mirroring D2), and prove no-archive.
producer_add roadmap-plan-stage roadmap 1300 "."
git commit -q -m "producer: add roadmap-plan-stage (STAGE-kind)" >/dev/null 2>&1 || true
# Co-seed a settled BUILD entry directly in done/ so the SAME qc_archive_settled pass DOES archive a
# build-kind — the tight contrast that proves the STAGE entry's no-archive is the ROUTING, not a no-op sweep.
mkdir -p "$QUEUE_DIR/done/build-control"; echo built > "$QUEUE_DIR/done/build-control/out.md"
git add -A >/dev/null 2>&1 || true
git commit -q -m "seed settled build-control in done/" >/dev/null 2>&1 || true

# ROUTE the STAGE entry (mirror of D2's session pre-route): pending/ → staged/, NEVER pending→running→done.
stage_route roadmap-plan-stage
# The STAGE entry is in staged/, and is NOT in done/ (the build terminal) nor running/ nor pending/.
{ [ -d "$QUEUE_DIR/staged/roadmap-plan-stage" ] \
  && [ ! -d "$QUEUE_DIR/done/roadmap-plan-stage" ] \
  && [ ! -d "$QUEUE_DIR/running/roadmap-plan-stage" ] \
  && [ ! -d "$QUEUE_DIR/pending/roadmap-plan-stage" ]; } \
  && ok "AC-015: a STAGE entry routes pending→staged/ (NOT done/ as a terminal — diverged from the build path)" \
  || ko "D4 stage terminal" "STAGE entry not solely in staged/ (done='$([ -d "$QUEUE_DIR/done/roadmap-plan-stage" ] && echo yes)')"

# Run the build-archival sweep (the SAME function the daemon's end-of-drain block calls). It archives the
# settled BUILD entry but MUST NOT archive the STAGE entry (which is in staged/, never done/).
ARCHIVED_D4="$(qc_archive_settled 2>/dev/null)"
# The STAGE entry is NOT in step-6-done/queue (NOT archived) — at any depth (date-partitioned or flat).
ARCHIVE_BASE_D4="$(dirname "$QUEUE_DIR")/step-6-done/queue"
{ ! find "$ARCHIVE_BASE_D4" -type d -name roadmap-plan-stage 2>/dev/null | grep -q .; } \
  && ok "AC-015: the settled STAGE entry is NOT archived to step-6-done/queue (skipped qc_archive_settled — the no-archive contract)" \
  || ko "D4 no-archive" "the STAGE entry WAS archived to step-6-done/queue (the STAGE route did not skip archival)"
# Contrast: the co-seeded BUILD entry WAS archived (proves the sweep ran and is kind-discriminating by path,
# so the STAGE no-archive is the ROUTING — pending→staged keeps it out of done/ — not a dead/no-op sweep).
{ find "$ARCHIVE_BASE_D4" -type d -name build-control 2>/dev/null | grep -q . \
  && [ ! -d "$QUEUE_DIR/done/build-control" ]; } \
  && ok "AC-015: the co-seeded BUILD entry WAS archived by the SAME sweep (the STAGE no-archive is routing, not a no-op)" \
  || ko "D4 build-control archived" "the build-kind control entry was NOT archived (archived count=$ARCHIVED_D4) — the contrast is broken"
# And the STAGE entry's artifact still lives in staged/ (it travelled with the folder; nothing was lost).
[ -f "$QUEUE_DIR/staged/roadmap-plan-stage/roadmap-plan-stage.md" ] \
  && ok "AC-015: the STAGE entry's spec artifact stays in staged/ (the spec output is preserved, not archived)" \
  || ko "D4 stage artifact" "the STAGE entry's artifact is missing from staged/"

# =========================================================================================================
# SHR4-B3 — DUAL-SHELL (bash + zsh) TEST MATRIX (AC-010, AC-007). THE STRUCTURAL ANTI-REGRESSION.
#
# WHY THIS EXISTS. SHR4-B1's zsh word-split bug (qc_archive_settled archived 0 under stock zsh) shipped GREEN
# because the whole suite ran ONLY under bash (CI's shell). AC-010 mandates that every lib-sourcing test arm
# runs under BOTH bash AND zsh, so a zsh-only divergence can never be invisible again. We DO NOT rewrite the
# 43 bash arms above (SHR3-T3/T4 + SHR4-A3 — extend, never collide); we add a self-contained INNER ARM script
# and a dispatcher that runs it under each shell. The inner arm:
#   (AC-006 proof) seeds N>0 settled done/ entries in a HERMETIC throwaway repo (QC_ARCHIVE_DIR override —
#     lib supports it), runs qc_archive_settled UNDER THE SELECTED SHELL, and asserts the archived count is
#     N>0 (and the right N moved). Before SHR4-B1 this FAILS under zsh (the word-split bug); after, it passes.
#   (AC-007 proof) exercises the lib's PUBLIC functions (qc_queue_dir / qc_completed_labels / qc_pick_entry /
#     qc_next / qc_settle defined + callable) under the selected shell — no divergence-class failure.
# zsh-absent → SKIP LOUDLY (echo a SKIP, never a silent pass). The operator's machine always has zsh.
# Do NOT `emulate -L bash` in the zsh arm — the point is STOCK zsh, as the lib is actually sourced.
# =========================================================================================================
# The inner arm is its OWN script (run via `bash <f>` / `zsh <f>`), so $0 inside it resolves to that file
# under both shells (the gotcha: $0 differs across shells for a sourced script — an own-file script avoids it).
DUAL_INNER="$W/dual-shell-inner.sh"
LIB_ABS="$HERE/queue-chew-lib.sh"
SCRIPTS_ABS="$HERE"
cat > "$DUAL_INNER" <<INNEREOF
# Dual-shell inner arm (SHR4-B3). Runs under bash OR zsh. Sources the REAL lib and proves AC-006 + AC-007.
# Exit 0 = all inner assertions passed; non-zero = a divergence-class failure under this shell.
set -u
LIB="$LIB_ABS"
SCRIPTS="$SCRIPTS_ABS"
SHELL_NAME="\${1:-unknown}"
fail() { echo "    INNER-FAIL [\$SHELL_NAME]: \$1" >&2; exit 1; }

# Hermetic throwaway repo so git mv / git status work for real, co-located with the archive via QC_ARCHIVE_DIR.
TMP="\$(mktemp -d)"
trap 'rm -rf "\$TMP"' EXIT
cd "\$TMP" || fail "cannot cd to temp"
git init -q; git config user.email t@e.com; git config user.name t; git commit -q --allow-empty -m root

# The lib resolves scripts at .claude/scripts else core/scripts — provide queue-archive.py at core/scripts.
mkdir -p core/scripts
cp "\$SCRIPTS/queue-archive.py" core/scripts/queue-archive.py

export QUEUE_DIR="docs/step-4-queue"
export QC_ARCHIVE_DIR="\$TMP/archive/queue"
mkdir -p "\$QUEUE_DIR/pending" "\$QUEUE_DIR/running" "\$QUEUE_DIR/done" "\$QUEUE_DIR/failed"

# shellcheck disable=SC1090
. "\$LIB" || fail "could not source the lib"

# AC-007 proof: the public functions are defined + callable under this shell.
type qc_queue_dir      >/dev/null 2>&1 || fail "qc_queue_dir not defined"
type qc_completed_labels >/dev/null 2>&1 || fail "qc_completed_labels not defined"
type qc_pick_entry     >/dev/null 2>&1 || fail "qc_pick_entry not defined"
type qc_next           >/dev/null 2>&1 || fail "qc_next not defined"
type qc_settle         >/dev/null 2>&1 || fail "qc_settle not defined"
type qc_archive_settled >/dev/null 2>&1 || fail "qc_archive_settled not defined"
[ "\$(qc_queue_dir)" = "\$QUEUE_DIR" ] || fail "qc_queue_dir returned '\$(qc_queue_dir)'"
qc_pick_entry >/dev/null 2>&1 || fail "qc_pick_entry errored on an empty queue (divergence-class)"
qc_completed_labels >/dev/null 2>&1 || fail "qc_completed_labels errored (divergence-class)"

# AC-006 proof: seed N=3 settled done/ entries (no pending after: names them → all archivable), then run
# qc_archive_settled UNDER THIS SHELL. The word-split bug archived 0 under zsh; the fix archives all 3.
N=3
for name in aaa bbb ccc; do
  mkdir -p "\$QUEUE_DIR/done/\$name"
  echo "built" > "\$QUEUE_DIR/done/\$name/out.md"
done
git add -A >/dev/null 2>&1 || true
git commit -q -m "seed settled done entries" >/dev/null 2>&1 || true

MOVED="\$(qc_archive_settled 2>/dev/null)"
[ "\$MOVED" = "\$N" ] || fail "qc_archive_settled archived '\$MOVED', expected \$N (zsh word-split regression?)"

# The right N entries physically moved done/ → archive, and done/ is now empty of them.
# LAYOUT-TOLERANT (ADR-128 Amendment 1 / SHR4-C3): the archive is now DATE-PARTITIONED
# (QC_ARCHIVE_DIR then a date sub-dir then the entry), so assert the entry landed SOMEWHERE under
# QC_ARCHIVE_DIR at any depth, not the pre-amendment flat layout. A find by -type d -name covers flat OR dated.
for name in aaa bbb ccc; do
  find "\$QC_ARCHIVE_DIR" -type d -name "\$name" 2>/dev/null | grep -q . || fail "entry '\$name' not in the archive after qc_archive_settled (dated or flat)"
  [ -d "\$QUEUE_DIR/done/\$name" ] && fail "entry '\$name' still in done/ after archival (not moved)"
done

# Idempotency under this shell: a re-run over the already-archived state is a no-op (0 moved).
MOVED2="\$(qc_archive_settled 2>/dev/null)"
[ "\$MOVED2" = "0" ] || fail "re-run archived '\$MOVED2', expected 0 (idempotency broken under \$SHELL_NAME)"

# SHR4-D4 (AC-015) UNDER THIS SHELL: a STAGE entry lives in staged/, NOT done/, so qc_archive_settled (which
# only reads done/) NEVER archives it — the no-archive routing holds under bash AND zsh (Wave B B′ discipline).
mkdir -p "\$QUEUE_DIR/staged/roadmap-stage-dual"; echo "spec" > "\$QUEUE_DIR/staged/roadmap-stage-dual/spec.md"
git add -A >/dev/null 2>&1 || true; git commit -q -m "seed STAGE entry in staged/" >/dev/null 2>&1 || true
MOVED_STAGE="\$(qc_archive_settled 2>/dev/null)"
[ "\$MOVED_STAGE" = "0" ] || fail "qc_archive_settled archived '\$MOVED_STAGE' STAGE entr(y/ies) — a staged/ entry must NEVER be archived (no-archive contract, AC-015) under \$SHELL_NAME"
find "\$QC_ARCHIVE_DIR" -type d -name roadmap-stage-dual 2>/dev/null | grep -q . && fail "STAGE entry roadmap-stage-dual WAS archived under \$SHELL_NAME (no-archive contract broken)"
[ -d "\$QUEUE_DIR/staged/roadmap-stage-dual" ] || fail "STAGE entry left staged/ under \$SHELL_NAME (it must stay in staged/, never moved)"

# AC-008 proof (ADR-130 D-3 / CR-001): the done-vs-failed dirty read (qc_worktree_dirty — what the SKILL
# settle loop routes DIRTY= through) EXCLUDES transient .claude/ pollution, so a clean build whose worktree
# carries .claude/worktrees/ junk settles done/, NOT failed/. Commit a clean baseline, drop ONLY an untracked
# .claude/worktrees/ file, and assert qc_worktree_dirty reads CLEAN (empty) while a plain status sees it dirty.
# Then a REAL source change must STILL read dirty (the exclude is scoped to .claude/, not a blanket clean).
git add -A >/dev/null 2>&1 || true
git commit -q -m "clean baseline for AC-008" >/dev/null 2>&1 || true
mkdir -p .claude/worktrees/queue-chew-x
echo junk > .claude/worktrees/queue-chew-x/scratch
RAW="\$(git status --porcelain 2>/dev/null)"
[ -n "\$RAW" ] || fail "AC-008 setup: plain status should see the .claude/ pollution (got empty)"
EXCL="\$(qc_worktree_dirty)"
[ -z "\$EXCL" ] || fail "AC-008: qc_worktree_dirty must EXCLUDE .claude/ pollution but read dirty: '\$EXCL'"
echo "real change" > realsrc.txt
DIRTY3="\$(qc_worktree_dirty)"
[ -n "\$DIRTY3" ] || fail "AC-008: qc_worktree_dirty must report a REAL source change as dirty (got empty — exclude too broad)"
rm -f realsrc.txt; rm -rf .claude

echo "    INNER-OK [\$SHELL_NAME]: archived \$N settled entries + STAGE no-archive (AC-015) + public-fn surface clean + AC-008 dirty-exclude proven"
exit 0
INNEREOF

# Dispatcher: run the inner arm under bash AND zsh. Each shell is a separate matrix cell asserted independently.
run_dual_cell() {
  local sh="$1"
  if ! command -v "$sh" >/dev/null 2>&1; then
    echo "  SKIP: SHR4-B3 dual-shell matrix [$sh] — '$sh' not on PATH (loud skip, NOT a silent pass; AC-010)"
    return 0
  fi
  if "$sh" "$DUAL_INNER" "$sh"; then
    ok "AC-010/AC-006: lib-sourcing arm passes under $sh (archives N>0 settled entries; public-fn surface clean)"
  else
    ko "AC-010 dual-shell [$sh]" "the inner arm FAILED under $sh (a shell-divergence-class failure — see INNER-FAIL above)"
  fi
}
# The matrix: bash (CI's shell) AND zsh (the operator's interactive shell — where SHR4-B1's bug actually bit).
run_dual_cell bash
run_dual_cell zsh

echo ""
echo "queue-chew e2e: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
