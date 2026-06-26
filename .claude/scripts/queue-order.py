#!/usr/bin/env python3
"""queue-order.py — the DETERMINISTIC add-time orderer for the autonomous work queue (ADR-122, AWQ-T2).

F9 BINDING OPERATOR DIRECTIVE — ZERO LLM involvement in the placement decision. This script computes the
`seq` (queue position) of a new entry purely from structured signals and the live `pending/` tape. It is
**deterministic**: the same inputs always produce the same `seq`. The only LLM role anywhere in the queue is
**advisory-only** ("did you mean to declare a dep?") and NEVER overrides the computed `seq` — the placement
decision is this script's, not a model's.

The no-guess contract (AC-004): when a dependency cannot be determined deterministically, this script will
**never guess** a position. It requires the operator to declare `after X`. Undeclared dependencies are
DERIVED ONLY from structured signals — `planned_files` overlap (two entries whose `planned_files` overlap
are not independent → they are ordered/flagged deterministically) and optional explicit `provides`/`needs`
tags. If overlap produces an irreconcilable ordering, the script emits a **conflict flag** — never a
probabilistic call.

The folder-as-truth / append-only contract (AC-005): the orderer reads the LIVE `docs/step-4-queue/pending/`
folder (folder-as-truth), not session memory. `pending/` is treated as **append-only** and entry writes are
**atomic** (atomic create / `git mv`) — there is no shared mutable JSON that producer and consumer both
write. The producer writes ONLY under `docs/step-4-queue/pending/`. Because of this, a producer append and a
concurrent daemon read cannot write-race (files-as-mailbox).

Logic-shape reuse note (architect nuance, AWQ-T2): this is NEW code. It does NOT call
`detectShippedSinkDrift` (a POST-BUILD, realized-state drift detector at
`core/scripts/workflows/orchestrated.js` ~L165, which takes `results`/`files_changed` after a build and is
not an add-time orderer). We reuse only the partition/overlap LOGIC SHAPE — "two items whose file sets
overlap are not independent" — re-expressed here for add-time `planned_files`.

ENTRY-AS-FOLDER (ADR-124). Each `pending/` entry is a SUBDIRECTORY `pending/<entry>/` containing the moved
source artifact plus a `sidecar.json` carrying at least
`{label, verb, seq, after?, planned_files?, target, provides?, needs?}`. The orderer reads the sidecars
(`pending/*/sidecar.json`) to learn the live tape; the bare `seq` integers form the ordered tape (lower seq
= earlier). (Pre-ADR-124 the entry was a flat `pending/<name>.md` + `pending/<name>.json` sidecar; the
folder-shape cutover is clean — the queue is new, no flat entries exist.)

ANCHOR-TOKEN CONVENTION (CR-002, binding — the `after X` resolution contract). The canonical anchor token
is the sidecar's explicit `label`, which the producer (`/queue add`, SKILL.md) MUST write as the
kind-prefixed `"${KIND}-${LABEL}"` (e.g. `orchestrated-foo`) — the SAME string as the sidecar basename. So
`after X` takes that EXACT token (`after orchestrated-foo`), not the bare target. `_label_seq` matches on
this `label`; if the producer ever omits `label`, `_load_tape` falls back to the entry DIR name — which,
by construction, is also `${KIND}-${LABEL}`, so resolution is unambiguous either way.

Subcommands:
  compute     --pending DIR [--after X | --top] [--planned-files f1,f2,...]   # print the seq for a NEW entry
  order       --pending DIR                                                    # print the resolved order (labels by seq)
  read        --pending DIR                                                    # dump the live tape as JSON
  dependents  --pending DIR --label LABEL                                      # print LABEL's dependents (both edge kinds)

The `dependents` subcommand (AWQ-T6) answers the daemon's arbiter question: "if LABEL failed/dirtied the
base, which queued entries are NOT independent of it?" It returns the UNION of two structurally-distinct
edge kinds — the SAME two the orderer already understands, surfaced (not recomputed) for the consumer:
  - `after_deps`     — entries whose sidecar `after == LABEL` (the explicit declared edge).
  - `overlap_deps`   — entries whose `planned_files` overlap LABEL's (the derived `planned_files`-overlap
                       edge, AC-004; the same overlap logic `_overlap_conflict` flags at add-time).
Consuming only `after_deps` would let a structurally-dependent-but-undeclared item stack on a broken base —
so the arbiter reads BOTH. This subcommand does NOT recompute or change `seq`; it is a read over the live
tape. Output JSON: {"label", "after_deps":[...], "overlap_deps":[...], "all_deps":[...]} (all_deps = union).

`compute` prints a single JSON object: {"seq": <int|float>, "conflict": <null|str>, "advisory": <null|str>}.
A non-null `conflict` is the deterministic conflict flag (exit 3); `advisory` is the LLM-advisory hint slot
(always null here — populated, if ever, by an advisory-only caller, never by this script's placement math).
"""
import json
import os
import sys
import argparse

# Seq spacing: entries are placed on an integer-spaced tape so an `after X` insert can land a FRACTIONAL
# seq strictly between X and its successor (a POSITION insert, not an end-of-tape gate — F4, load-bearing).
SEQ_STEP = 100
SEQ_FIRST = SEQ_STEP


def _die(msg, code=2):
    sys.stderr.write(f"queue-order: {msg}\n")
    sys.exit(code)


def _load_tape(pending_dir):
    """Read the LIVE pending/ folder (folder-as-truth) and return the entries sorted by seq.

    ENTRY-AS-FOLDER (ADR-124). Each queue entry is a SUBDIRECTORY of pending/ containing the moved source
    artifact + a `sidecar.json`: pending/<entry>/sidecar.json. This reads that folder shape — it iterates
    `pending/*/sidecar.json` (one entry per subdir), NOT the legacy flat `pending/*.json`. Label =
    sidecar.label or the entry DIR name. Everything downstream (seq sort, _overlap_conflict, dependents,
    compute) is unchanged — it operates on the parsed sidecars.

    Append-only + atomic: we only READ here; we never mutate pending/. Missing dir -> empty tape.
    """
    if not os.path.isdir(pending_dir):
        return []
    entries = []
    for entry_name in sorted(os.listdir(pending_dir)):
        entry_dir = os.path.join(pending_dir, entry_name)
        if not os.path.isdir(entry_dir):
            continue
        path = os.path.join(entry_dir, "sidecar.json")
        if not os.path.isfile(path):
            continue
        try:
            with open(path, encoding="utf-8") as fh:
                side = json.load(fh)
        except (json.JSONDecodeError, OSError) as e:
            _die(f"unreadable sidecar {path}: {e}")
        if not isinstance(side, dict):
            _die(f"sidecar {path} is not a JSON object")
        label = side.get("label") or entry_name
        side["label"] = label
        if "seq" not in side:
            _die(f"sidecar {path} missing required 'seq'")
        entries.append(side)
    entries.sort(key=lambda e: (e["seq"], e["label"]))
    return entries


def _label_seq(entries, label):
    for e in entries:
        if e["label"] == label:
            return e["seq"]
    return None


def _overlap_conflict(entries, planned_files, after, top):
    """DERIVE undeclared deps ONLY from structured signals (planned_files overlap).

    Logic SHAPE reused from detectShippedSinkDrift: two items whose file sets overlap are NOT independent.
    Returns (conflict_str_or_None). We NEVER guess a position from overlap — we deterministically FLAG it
    when a placement would sit BEFORE an entry it overlaps with and no explicit `after`/`--top` ordering was
    declared to justify the relative position. An explicit, HONORABLE ordering declaration is the operator's
    call and suppresses the flag (the operator owns it); an undeclared overlap — or an UNHONORABLE `after`
    (a forward-reference whose anchor is absent, so the declared position can't actually be honored yet) —
    is surfaced, never silently reordered.
    """
    if not planned_files:
        return None
    newset = set(planned_files)
    overlappers = [e for e in entries if newset & set(e.get("planned_files") or [])]
    if not overlappers:
        return None
    # An explicit ordering declaration suppresses the flag ONLY when it is HONORABLE (CR-004):
    #  - `--top` is always honorable (front of tape, no anchor to resolve).
    #  - `after X` is honorable only when X is PRESENT in the tape; when X is ABSENT the declared position
    #    is a forward-reference that can't be honored yet, so a real overlap with a PRESENT entry must still
    #    be surfaced rather than masked behind an unhonorable declaration.
    if top:
        return None
    if after is not None and _label_seq(entries, after) is not None:
        return None
    # Undeclared overlap (or overlap under an unhonorable forward-ref `after`) with one or more existing
    # entries -> deterministic conflict flag (never a guess).
    labels = ", ".join(sorted(e["label"] for e in overlappers))
    return (
        f"planned_files overlap with existing entr(y/ies) [{labels}] but no `after`/`--top` declared — "
        f"not independent; declare `after X` to order deterministically (never guess)"
    )


def cmd_compute(a):
    entries = _load_tape(a.pending)
    planned = [p for p in (a.planned_files.split(",") if a.planned_files else []) if p]

    conflict = _overlap_conflict(entries, planned, a.after, a.top)

    # --- deterministic placement math (no LLM, no randomness) ---
    if not entries:
        # 1. Empty queue -> the first seq.
        seq = SEQ_FIRST
    elif a.top:
        # 4. --top -> jump to front: strictly below the current min.
        seq = entries[0]["seq"] - SEQ_STEP
    elif a.after is not None:
        x_seq = _label_seq(entries, a.after)
        if x_seq is None:
            # 5. Forward-referenced `after X` (X not yet present): record the edge, place provisionally at
            # the TAIL (so it cannot violate an edge to an absent predecessor), and surface the unresolved
            # edge. We never guess a mid-tape position for an absent anchor.
            tail = entries[-1]["seq"]
            seq = tail + SEQ_STEP
            if conflict is None:
                conflict = (
                    f"forward-reference: anchor '{a.after}' not yet in pending/ — edge recorded, placed "
                    f"provisionally at tail (seq {seq}); resolve when '{a.after}' arrives (never guess)"
                )
        else:
            # 3. `after X` mid-tape topological insert: a seq strictly between X and its successor (F4
            # POSITION insert, not an end-of-tape gate). If X is last, append after it.
            successors = [e["seq"] for e in entries if e["seq"] > x_seq]
            if successors:
                nxt = min(successors)
                # Fractional midpoint keeps the tape deterministic and stable without renumbering.
                mid = (x_seq + nxt) / 2.0
                # CR-001 (F9, load-bearing): after enough consecutive `after X` inserts into the SAME gap
                # the float midpoint UNDERFLOWS until it equals x_seq (e.g. A=100,B=101 reaches 100.0 at
                # ~insert 46) — the new entry would then sort AT/BEFORE its own anchor, a SILENT wrong
                # placement with no flag. F9's whole point is "never a wrong placement", so when the
                # midpoint is NOT strictly between x_seq and nxt we emit a deterministic conflict (exit 3)
                # advising a renumber/compaction pass rather than return a colliding seq. We NEVER return a
                # seq equal to or below the declared anchor.
                if mid <= x_seq or mid >= nxt:
                    if conflict is None:
                        conflict = (
                            f"gap exhausted: no representable seq strictly between anchor '{a.after}' "
                            f"(seq {x_seq}) and its successor (seq {nxt}) — float midpoint underflowed; "
                            f"run a renumber/compaction pass on pending/ to reopen the gap, then re-add "
                            f"(never collide with the anchor)"
                        )
                    # Leave seq AT the anchor only as a sentinel; the exit-3 below halts the caller before
                    # any write, so this colliding value is never persisted.
                    seq = x_seq
                else:
                    seq = mid
            else:
                seq = x_seq + SEQ_STEP
    else:
        # 2. Append (default, FIFO by seq) -> after the current max.
        seq = entries[-1]["seq"] + SEQ_STEP

    out = {"seq": seq, "conflict": conflict, "advisory": None}
    print(json.dumps(out))
    # A deterministic conflict flag is a non-zero exit so the caller (the /queue add door) can halt and ask
    # the operator to declare `after X` rather than proceed on an undeclared/forward-referenced placement.
    if conflict is not None:
        sys.exit(3)


def cmd_order(a):
    entries = _load_tape(a.pending)
    print(json.dumps([{"label": e["label"], "seq": e["seq"]} for e in entries]))


def cmd_read(a):
    print(json.dumps(_load_tape(a.pending), indent=2))


def _dependents(entries, label):
    """Return LABEL's dependents from BOTH edge kinds (AWQ-T6, AC-017).

    The arbiter (queue-chew SKILL) calls this to decide skip-vs-park when LABEL fails or dirties the base.
    Two structurally-distinct edges — surfaced from the SAME tape signals the orderer already understands,
    NOT recomputed:
      - after_deps:   entries whose sidecar `after == LABEL` (explicit declared edge).
      - overlap_deps: entries whose `planned_files` overlap LABEL's (derived `planned_files`-overlap edge,
                      reusing the `_overlap_conflict` "overlapping file sets are not independent" logic).
    LABEL itself is never its own dependent. all_deps is the de-duplicated union, sorted for determinism.
    """
    target = next((e for e in entries if e["label"] == label), None)
    target_files = set((target.get("planned_files") or [])) if target else set()

    after_deps = sorted(
        e["label"] for e in entries
        if e["label"] != label and e.get("after") == label
    )
    overlap_deps = sorted(
        e["label"] for e in entries
        if e["label"] != label and target_files and (target_files & set(e.get("planned_files") or []))
    )
    all_deps = sorted(set(after_deps) | set(overlap_deps))
    return {"label": label, "after_deps": after_deps, "overlap_deps": overlap_deps, "all_deps": all_deps}


def cmd_dependents(a):
    entries = _load_tape(a.pending)
    print(json.dumps(_dependents(entries, a.label)))


def main():
    p = argparse.ArgumentParser(prog="queue-order")
    sub = p.add_subparsers(required=True)

    pc = sub.add_parser("compute")
    pc.add_argument("--pending", required=True, help="path to the live docs/step-4-queue/pending/ folder")
    g = pc.add_mutually_exclusive_group()
    g.add_argument("--after", default=None, help="declare this entry lands immediately after label X")
    g.add_argument("--top", action="store_true", help="jump to the front of the tape")
    pc.add_argument("--planned-files", default=None, help="comma-separated planned_files for overlap derivation")
    pc.set_defaults(fn=cmd_compute)

    po = sub.add_parser("order")
    po.add_argument("--pending", required=True)
    po.set_defaults(fn=cmd_order)

    pr = sub.add_parser("read")
    pr.add_argument("--pending", required=True)
    pr.set_defaults(fn=cmd_read)

    pd = sub.add_parser("dependents")
    pd.add_argument("--pending", required=True)
    pd.add_argument("--label", required=True, help="the label whose dependents (both edge kinds) to print")
    pd.set_defaults(fn=cmd_dependents)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
