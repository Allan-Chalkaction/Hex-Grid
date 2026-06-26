---
name: queue
description: "Add a build job to the autonomous work queue: move-on-advance — resolve the target artifact, git mv it into a pending/<entry>/ folder with a sidecar carrying a deterministically-computed seq (zero LLM in placement); supports after-X and --top."
user_invocable: true
---

# /queue — the producer surface for the autonomous work queue (ADR-122; ADR-124 move-on-advance)

`/queue add <kind> <target> [after <X> | --top]` is the **operator-facing producer door** of the autonomous
work queue. It **move-on-advances** a build job into the queue: it resolves `<target>` to a source artifact,
creates an entry **FOLDER** `docs/step-4-queue/pending/${KIND}-${LABEL}/`, **`git mv`s the source artifact INTO it**,
and writes `docs/step-4-queue/pending/${KIND}-${LABEL}/sidecar.json` carrying
`{label, verb, seq, after?, planned_files?, target}`. The in-queue artifact **IS** the build target (no
external `docs/step-3-specs/` build path). The Wave-2 daemon (the consumer) is the only mover of entries
through the lifecycle; the producer only ever **appends** an entry folder to `pending/`.

> **Entry-as-folder (ADR-124, binding).** A queue entry is a **folder** under `pending/`, not a flat file.
> `docs/step-4-queue/pending/${KIND}-${LABEL}/` contains (a) the moved source artifact (an idea `.md`, or a whole
> spec/plan sub-tree) and (b) `sidecar.json`. The within-queue drain (`pending → running → {done|failed}`
> INSIDE `docs/step-4-queue/`) is **preserved** — only the producer **move-IN** (artifact → `pending/<entry>/`) is
> new, and the build **READS the in-queue artifact**; entries never move **OUT** of `docs/step-4-queue/` during the
> drain. ADR-124 EXTENDS ADR-123 D-3 (the within-queue-drain invariant) — the move-IN is upstream of the
> drain, the poll is preserved, there is NO move-out.

> **Anchor-token convention (CR-002, binding).** The sidecar's `label` is the canonical anchor token and is
> written as the kind-prefixed **`${KIND}-${LABEL}`** (e.g. `orchestrated-foo`) — the same string as the
> entry **folder** name. So `after X` takes that **exact token** (`after orchestrated-foo`), NOT the bare
> target. This makes `after X` resolve a PRESENT anchor (a real position insert) instead of misreading it as
> an absent forward-reference. The same convention is documented in `queue-order.py`.

This door is **pure additive substrate** — it touches no shared-state lever (no merge, no push to main, no
PR). A wrong placement could silently stack a build on the wrong base, so the placement decision is owned by
the **deterministic** `queue-order.py` orderer (AWQ-T2), NOT by a model.

> **Substrate path resolution (consumer-safe — ADR-031).** The orderer lives at `core/scripts/queue-order.py`
> when dogfooding inside claude-infra, but at `.claude/scripts/queue-order.py` in a consumer repo. Resolve the
> prefix first: `S=.claude/scripts; [ -d "$S" ] || S=core/scripts`, then call `$S/queue-order.py`.

## Usage

- `/queue add <kind> <target>` — **default**: appends the new entry **FIFO by `seq`** (after the current max).
- `/queue add <kind> <target> after <X>` — inserts the entry **immediately after `X`** — a **POSITION
  insert** (F4, load-bearing): an entry added `after X` where X is #2 of 20 lands at **#3** (adjacent to its
  dependency), NOT appended at the tail.
- `/queue add <kind> <target> --top` — **jumps to the front** of the tape (a `seq` below the current min).

`<kind>` is one of the live BUILD KINDS `{orchestrated, nimble, chain, loop}` (aligned with
`launch-manifest.py`). The producer accepts the kind argument; the v1 *rejection* of planning verbs
(`roadmap`/`sweep`) is the Wave-2 daemon's job (AC-010), not this door's.

### Target resolution (ADR-124 — what `<target>` names and what gets moved in)

`<target>` is resolved to the **literal path the operator names** — the source artifact that becomes the
build input:

- An idea `.md` or a folder under `docs/step-1-ideas/` (e.g. `docs/step-1-ideas/2026-06-17-foo.md`).
- A plan/spec folder under `docs/step-3-specs/` (e.g. `docs/step-3-specs/foo/` or a wave sub-tree
  `docs/step-3-specs/foo/waves/wave-1/`).
- Any other repo path the operator points at.

**Resolution rule.** Resolve the literal path first. If `<target>` is a **bare label** (not an existing
path), it is interpreted as the `${LABEL}` portion and the producer expects a co-named source artifact to
exist (e.g. `docs/step-3-specs/<label>/`); if none resolves, HALT and ask the operator to name the path —
**never invent one**.

The producer then **`git mv`s the resolved source artifact INTO the entry folder** and records, in the
sidecar's **`target`** field, the **entry-relative build-input path**:

- Default `target = "."` — the build input is the **entry folder itself** (the whole moved artifact).
- A sub-path (e.g. `target = "waves/wave-1"`) when a moved spec folder has a build sub-tree the daemon
  should point the launch at.

The daemon resolves `TARGET = docs/step-4-queue/running/<entry>/<sidecar.target>` at drain time (SA-002 validates
it stays under `docs/step-4-queue/`). The in-queue artifact IS the build target — there is no second external path.

### Reversibility — a pre-chew dequeue/cancel moves the artifact BACK (binding contract)

Because the producer **moves** the source artifact into the queue, a cancel/dequeue **before the chew picks
it up** MUST `git mv` the artifact **back to its origin** (or to a terminal sink) so the cancel does not
strand it. The contract: a cancelled `pending/<entry>/` is restored by moving its source artifact out of the
entry folder back to the path it came from, then removing the (now sidecar-only) entry folder. *(A full
`/queue cancel` verb is out of scope for W1 — this records the reversibility contract; an operator cancels
by `git mv`-ing the artifact back by hand until the verb ships.)*

## The add flow (the wire-to-consumer atom — AC-007)

The add door MUST **call `queue-order.py`** to compute `seq` *before* it writes the entry. A defined-but-
unwired orderer is the exact failure class AC-007 exists to close — so the call is load-bearing, not advisory.

1. **Read the live folder (folder-as-truth).** The orderer reads the live `docs/step-4-queue/pending/` contents
   directly — never session memory — so a producer append and a concurrent daemon read cannot write-race.

1b. **Derive `planned_files` deterministically (Wave 3 — ADR-124).** If the operator did NOT pass an explicit
   `--planned-files`, DERIVE the entry's `planned_files` from the queued artifact itself — the de-duplicated
   union of the `- planned_files: [...]` declarations in its wave-spec ticket blocks — so the orderer's overlap
   edges (`_overlap_conflict` add-time + `dependents` arbiter) become **live** for a roadmapped spec. A raw plan
   yields the empty set (overlap detection stays inactive — correct; it isn't roadmapped, so the orderer falls
   back to explicit `after X`, never a guess). An explicit operator `--planned-files` WINS (override). **ZERO
   LLM (F9)** — derivation reads DECLARED structure, it never predicts.

   ```bash
   S=.claude/scripts; [ -d "$S" ] || S=core/scripts   # self-contained prefix (ADR-031) — do NOT rely on a later step's assignment
   # $SOURCE = the resolved source artifact for <target> (still at its origin, before the move-in below).
   if [ -z "${PF:-}" ]; then
     PF="$(python3 "$S/queue-derive-planned-files.py" "$SOURCE")"   # comma-separated union; empty for a raw plan
   fi
   ```

2. **Compute `seq` deterministically — CALL `queue-order.py`.** Pass the placement flag through verbatim:

   ```bash
   S=.claude/scripts; [ -d "$S" ] || S=core/scripts
   # Mint the lifecycle folders on first use (idempotent). docs/ is NOT distributed to consumers
   # (only core/ is symlinked), so a fresh consumer has no docs/step-4-queue/ — mint it here so the first
   # `/queue add` cannot fail on a missing folder. Folder-as-truth: pending/running/done/failed.
   mkdir -p docs/step-4-queue/pending docs/step-4-queue/running docs/step-4-queue/done docs/step-4-queue/failed
   Q="docs/step-4-queue/pending"
   # default (FIFO):  queue-order.py compute --pending "$Q"
   # after X:         queue-order.py compute --pending "$Q" --after "$X"
   # --top:           queue-order.py compute --pending "$Q" --top
   RESULT="$(python3 "$S/queue-order.py" compute --pending "$Q" ${AFTER:+--after "$AFTER"} ${TOP:+--top} ${PF:+--planned-files "$PF"})"
   RC=$?
   SEQ="$(printf '%s' "$RESULT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["seq"])')"
   ```

   `queue-order.py` is **deterministic**: the same inputs always produce the same `seq`. If it exits **3**
   (a conflict flag — an undeclared `planned_files` overlap, or a forward-referenced `after X` whose anchor
   is absent), **HALT and ask the operator to declare `after X`** — **never guess** a position. The orderer
   makes the placement decision; any LLM hint ("did you mean to declare a dep?") is **advisory-only** and
   never overrides the computed `seq`.

3. **Move-on-advance — create the entry FOLDER, `git mv` the artifact in, write the sidecar (ADR-124).**
   Exactly **one** entry per `add`, as an **atomic, append-only** create of a `pending/<entry>/` **folder**:

   ```bash
   # 0. KIND VALIDATION (SHR4-C1, AC-011) — fail-fast BEFORE any side effect (no entry folder, no git mv).
   #    Producer-time gate: $KIND must be one of the canonical BUILD KINDS. The SINGLE SOURCE OF TRUTH is
   #    launch-manifest.py's KINDS set (same set cmd_add:88 validates against) — we SHELL OUT to read it,
   #    never inline a second copy of the list (drift guard). $KIND is passed as a DISTINCT quoted argv
   #    element to python3 (SA-002 — never composed into a command string). On a miss: an `invalid kind`
   #    error to stderr + a non-zero exit, with $SOURCE STILL AT ITS ORIGIN (nothing moved, no DEST minted).
   #    This is ORDERED STRICTLY BEFORE both `mkdir -p "$DEST"` and `git mv` so a rejected add leaves ZERO
   #    residue. Distinct from the chew-time AC-010 BUILD-KINDS allowlist (qc_validate_kind, far too late —
   #    the artifact is already moved by then); this is the producer-time fail-fast.
   S=.claude/scripts; [ -d "$S" ] || S=core/scripts
   if ! python3 - "$KIND" "$S/launch-manifest.py" <<'PYEOF'
import importlib.util, sys
kind, lm_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("_lm", lm_path)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if kind in m.KINDS else 1)   # KINDS = single source of truth (launch-manifest.py:30)
PYEOF
   then
     echo "queue: invalid kind '$KIND' — expected one of the BUILD KINDS {orchestrated, nimble, chain, loop} (launch-manifest.py KINDS). Source artifact left un-moved at its origin." >&2
     exit 2
   fi

   # 0b. PRODUCER-SIDE ATTENDED CONFIRM (SHR4-D3, AC-016) — the consent point for BUILD-BY-DEFAULT.
   #    Post-ADR-132 the daemon builds a queued entry UNATTENDED by default (the posture flip — D2). Consent
   #    moves HERE, to queue-time: choosing the routing verb at `/queue add` IS the consent, and the producer
   #    PRESENTS THE BUILD for an ATTENDED CONFIRMATION before it commits the entry to the queue. This is the
   #    producer-side counterpart to the daemon's width/time guard (queue-chew/SKILL.md, D2): the operator
   #    consents at queue-time; the daemon caps resource at drain-time. It is a REAL gate (not nominal) —
   #    ORDERED STRICTLY AFTER C's kind-validation (validate first, then confirm) and STRICTLY BEFORE the
   #    `mkdir -p "$DEST"` + `git mv` (so a non-confirmed add leaves ZERO residue — $SOURCE stays at origin).
   #    `QUEUE_REFUSE_RAW_PLAN=1` (the D2 opt-OUT) is honored consistently: under it the producer DECLINES to
   #    queue a raw-plan entry that would build unattended, telling the operator to `/roadmap` it first.
   #    This confirm governs WHETHER A RAW PLAN IS QUEUED TO BUILD — it does NOT authorize the daemon to
   #    merge/push (the shared-state floor is untouched: a queued build lands on a stacked branch, reviewable
   #    and revertible; the operator-driven merge lever is intact).
   #    Detect a RAW PLAN the same way the daemon's readiness gate does (ONE detector shape — no second copy):
   READINESS="$(python3 "$S/queue-detect-readiness.py" "$SOURCE" 2>/dev/null || echo NOT_PLANNED)"
   if [ "$KIND" = "orchestrated" ] && [ "$READINESS" != "PLANNED" ]; then
     # A raw (un-decomposed) plan that will build unattended under build-by-default → REQUIRE attended confirm.
     if [ "${QUEUE_REFUSE_RAW_PLAN:-0}" = "1" ]; then
       echo "queue: DECLINED — '$KIND $LABEL' is a RAW PLAN and QUEUE_REFUSE_RAW_PLAN=1 is set (opt-OUT). Not queued. /roadmap it first, then queue the sliced spec. Source artifact left un-moved at its origin." >&2
       exit 3
     fi
     # ATTENDED CONFIRM: present the build for the operator's explicit go-ahead BEFORE committing the entry.
     # The operator confirms (choosing the verb IS the consent); on anything but an explicit yes, DECLINE and
     # leave $SOURCE at origin. (Non-interactive contexts: set QUEUE_CONFIRM_RAW_PLAN=1 to pre-confirm, or
     # QUEUE_REFUSE_RAW_PLAN=1 to decline — never a silent default-yes for a raw plan.)
     echo "queue: ATTENDED CONFIRM — '$KIND $LABEL' is a RAW PLAN; under build-by-default the daemon will run the full cto→architect→pm-spec→decompose funnel UNATTENDED and stack the build on a branch (it never merges to main). Confirm to queue it for an unattended build." >&2
     if [ "${QUEUE_CONFIRM_RAW_PLAN:-0}" = "1" ]; then
       CONFIRM=yes
     else
       printf 'queue: build this raw plan unattended? [y/N] ' >&2; read -r CONFIRM </dev/tty 2>/dev/null || CONFIRM=n
     fi
     case "$CONFIRM" in
       y|Y|yes|YES) : ;;   # consented — fall through to commit the entry
       *) echo "queue: DECLINED — not confirmed; '$KIND $LABEL' NOT queued. Source artifact left un-moved at its origin." >&2; exit 3 ;;
     esac
   fi

   ENTRY="${KIND}-${LABEL}"
   DEST="$Q/$ENTRY"
   mkdir -p "$DEST"
   # MOVE-IN: git mv the resolved source artifact INTO the entry folder (the in-queue artifact IS the build
   #   target — ADR-124). $SOURCE is the path target-resolution resolved (an idea .md, a spec folder, …).
   git mv "$SOURCE" "$DEST/"
   # TARGET = the entry-relative build-input path. Default "." = the entry folder itself; a sub-path (e.g.
   #   "waves/wave-1") when a moved spec folder has a build sub-tree the daemon should point the launch at.
   TARGET="${TARGET:-.}"
   # The sidecar persists an explicit `label` = "${KIND}-${LABEL}" — the canonical `after X` anchor token
   # (CR-002) — plus `target` (the entry-relative build input). Without `label` the orderer can't resolve a
   # present anchor and misreads it as a forward-reference.
   python3 -c "import json;json.dump({'label':'$ENTRY','verb':'$KIND','seq':$SEQ,'target':'$TARGET'${AFTER:+,'after':'$AFTER'}${PF:+,'planned_files':'$PF'.split(',')}},open('$DEST/sidecar.json','w'))"
   ```

   Exactly **one** entry folder per `add` — never a batch, never a rewrite of existing entries. The entry is
   a **folder** under `docs/step-4-queue/pending/<entry>/` (ADR-124 entry-as-folder), **not** a flat
   `docs/step-4-queue/pending/<kind>-<label>.md` and **not** the legacy flat `docs/step-4-queue/<kind>-<label>.md`. The
   move-IN is the only new step over Wave 2; the within-queue drain and the README split are unchanged.

## Contracts (binding — re-stated here as a co-grep target with the orderer)

- **Zero-LLM placement (F9, AC-004):** the placement decision is `queue-order.py`'s — **deterministic**, no
  randomness. The script will **never guess**; any LLM role is **advisory-only** and never overrides the
  computed `seq`.
- **Folder-as-truth / append-only (AC-005):** the producer reads the live `docs/step-4-queue/pending/` folder
  (**folder-as-truth**), not session memory, and writes **only** under `pending/` as an **atomic**,
  append-only create. No shared mutable JSON is written by both producer and consumer — the consumer (the
  Wave-2 daemon) is the only mover of entries, so the producer append and the daemon read cannot write-race
  (files-as-mailbox).

## Verification

- `git grep -n 'queue-order' core/skills/queue/SKILL.md` shows the orderer **invocation** in the add flow
  (AC-007 — the call fires, it is not merely referenced).
- `core/scripts/test-queue-order.sh` exercises the **add → order → write** path end-to-end (the test drives
  the same `compute --pending … → write entry` path this door invokes), proving the wiring, not just that
  the orderer function exists.
