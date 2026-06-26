#!/usr/bin/env python3
"""shelf-match.py — the DETERMINISTIC shelf/bucket-placement floor for an inbox item (ADR-126, F9; SHR3-T5).

F9 BINDING (ADR-126 D-1) — ZERO LLM involvement in the decision. This script answers ONE question
deterministically: "does an inbox item structurally reconcile with an EXISTING shelf item or live jam?" —
the shelf-aware-reconciliation / no-go-dampener floor `/sweep` § 2b + Gate G1 act on. It reads the LIVE
shelves (`docs/step-1-ideas/backlog/`, `docs/step-1-ideas/parked/`) and live jams
(`docs/step-2-planning/jam-*/`) — folder-as-truth — and emits the routing the skill acts on. The placement
is THIS script's, never a model's; the only LLM role is **advisory-only** and NEVER overrides `decision`
(exactly `queue-order.py`'s discipline).

Crucially, this is the **structural-match floor ONLY**, not a free-shelving recommender. The operator owns
the backlog/park verdict (those are operator authority — `/sweep` Notes). So this script NEVER invents a
"park this" or "backlog this" call; it deterministically detects when an item matches an item already on a
shelf (route-to-pool, § 2b) or a live jam (route-to-jam, Gate G1), and ABSTAINS otherwise — the abstain band
is exactly where the operator/LLM decides the shelf verdict.

The no-guess contract (ADR-126 D-3): on an item that matches nothing on a shelf or in a jam, the script
emits `decision: "abstain"` (inbox stays / the operator decides) — never a probabilistic "probably backlog".
A `route-to-pool` / `route-to-jam` verdict is asserted ONLY on a strong deterministic slug/token match
(>= MATCH_THRESHOLD); the band [ABSTAIN_THRESHOLD, MATCH_THRESHOLD) is the no-guess ABSTAIN zone.

The `reason` field (ADR-126 D-2) is the script's OWN deterministic justification — the matched target +
the overlap rule that fired (e.g. "token overlap 0.80 >= 0.66 with backlog item 'configure-mcps-per-repo.md'").

folder-as-truth (ADR-126 D-4): the shelf + jam candidate sets are read LIVE from the filesystem.

Subcommands:
  match  --item SLUG --backlog DIR --parked DIR --jams DIR   # which shelf/jam (if any) does ITEM reconcile to?

`match` prints {"decision": "route-to-pool"|"route-to-jam"|"abstain", "reason": <str>,
"confidence": "high"|"low"|null, "target": <relpath|null>, "shelf": "backlog"|"parked"|"jam"|null,
"advisory": null}. A `route-to-*` verdict exits 3 (deterministic flag) so the caller routes deterministically
rather than minting a new cluster (the § 2b / G1 dampener).
"""
import json
import os
import re
import sys
import argparse

# Slug/token-overlap floor for a strong structural shelf/jam match. The band [ABSTAIN_THRESHOLD,
# MATCH_THRESHOLD) is the no-guess ABSTAIN zone (the operator/LLM decides the shelf verdict there). These
# are deterministic constants — NOT model-tuned weights.
MATCH_THRESHOLD = 0.66
ABSTAIN_THRESHOLD = 0.34

_SKIP_NAMES = {"README.md", "INDEX.md"}
_PREFIX_RE = re.compile(r"^(?:DEFER-|FOLLOWUP-|ARCHIVED-|\d{4}-\d{2}-\d{2}-)+", re.IGNORECASE)
_POOL_SUFFIX = "-pool"
_JAM_PREFIX = "jam-"
_STOPWORDS = {"the", "a", "an", "and", "or", "of", "to", "for", "in", "on", "is", "be", "vs"}


def _die(msg, code=2):
    sys.stderr.write(f"shelf-match: {msg}\n")
    sys.exit(code)


def _normalize_slug(name):
    base = name[:-3] if name.endswith(".md") else name
    base = _PREFIX_RE.sub("", base)
    if base.endswith(_POOL_SUFFIX):
        base = base[: -len(_POOL_SUFFIX)]
    base = base.lower()
    base = re.sub(r"[^a-z0-9]+", "-", base).strip("-")
    return base


def _tokens(slug):
    return {t for t in slug.split("-") if t and t not in _STOPWORDS}


def _jaccard(a, b):
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def _shelf_items(shelf_dir):
    """Read a LIVE shelf folder (folder-as-truth) -> list of (filename, token_set). Missing -> empty."""
    items = []
    if not os.path.isdir(shelf_dir):
        return items
    for fn in sorted(os.listdir(shelf_dir)):
        if not fn.endswith(".md") or fn in _SKIP_NAMES:
            continue
        items.append((fn, _tokens(_normalize_slug(fn))))
    return items


def _jam_slugs(jams_dir):
    """Read LIVE jam folders (folder-as-truth) -> list of (jam_dirname, token_set of its slug). Missing -> empty.

    A jam workspace is `docs/step-2-planning/jam-<slug>/`. We match the item against the jam slug's tokens.
    """
    items = []
    if not os.path.isdir(jams_dir):
        return items
    for dn in sorted(os.listdir(jams_dir)):
        if not dn.startswith(_JAM_PREFIX):
            continue
        if not os.path.isdir(os.path.join(jams_dir, dn)):
            continue
        slug = dn[len(_JAM_PREFIX):]
        items.append((dn, _tokens(_normalize_slug(slug))))
    return items


def _best(item_tokens, candidates):
    best_name, best_score = None, 0.0
    for name, toks in candidates:
        score = _jaccard(item_tokens, toks)
        if score > best_score:
            best_name, best_score = name, score
    return best_name, best_score


def cmd_match(a):
    item_tokens = _tokens(_normalize_slug(a.item))

    backlog = [(f, t) for f, t in _shelf_items(a.backlog)]
    parked = [(f, t) for f, t in _shelf_items(a.parked)]
    jams = _jam_slugs(a.jams)

    # --- deterministic match math (no LLM, no randomness) ---
    # Evaluate shelves first (§ 2b reconciliation), then jams (Gate G1 jam-refork dampener). On a tie the
    # higher score wins; the iteration order (backlog, parked, jam) breaks an exact tie deterministically.
    b_name, b_score = _best(item_tokens, backlog)
    p_name, p_score = _best(item_tokens, parked)
    j_name, j_score = _best(item_tokens, jams)

    pool_best = None  # (shelf, name, score)
    if b_name is not None and b_score >= (p_score if p_name else -1):
        pool_best = ("backlog", b_name, b_score)
    elif p_name is not None:
        pool_best = ("parked", p_name, p_score)

    # Choose the single strongest signal across shelves and jams.
    shelf_score = pool_best[2] if pool_best else 0.0
    jam_score = j_score if j_name else 0.0

    if max(shelf_score, jam_score) >= MATCH_THRESHOLD:
        if shelf_score >= jam_score:
            shelf, target, score = pool_best
            decision, confidence = "route-to-pool", "high"
            reason = (
                f"token overlap {round(score, 2)} >= {MATCH_THRESHOLD} with {shelf} item '{target}' "
                f"— route to accumulating pool (§ 2b dampener), do not mint a new cluster"
            )
            out_shelf = shelf
        else:
            target, score, shelf = j_name, jam_score, "jam"
            decision, confidence = "route-to-jam", "high"
            reason = (
                f"token overlap {round(score, 2)} >= {MATCH_THRESHOLD} with live jam '{target}' "
                f"— route as ingest-to-jam (Gate G1 jam-refork dampener), do not fork a new cluster"
            )
            out_shelf = "jam"
    elif max(shelf_score, jam_score) >= ABSTAIN_THRESHOLD:
        # no-guess: ambiguous band -> abstain (the operator/LLM owns the shelf verdict).
        if shelf_score >= jam_score:
            target, out_shelf, score = (pool_best[1], pool_best[0], shelf_score) if pool_best else (None, None, 0.0)
        else:
            target, out_shelf, score = j_name, "jam", jam_score
        decision, confidence = "abstain", "low"
        reason = (
            f"best match {round(score, 2)} in abstain band "
            f"[{ABSTAIN_THRESHOLD},{MATCH_THRESHOLD}) ({out_shelf} '{target}') — operator/LLM decides shelf"
        )
    else:
        decision, confidence, target, out_shelf = "abstain", "high", None, None
        reason = f"no shelf/jam match >= {ABSTAIN_THRESHOLD} — inbox stays, operator decides verdict"

    out = {
        "decision": decision,
        "reason": reason,
        "confidence": confidence,
        "target": target,
        "shelf": out_shelf,
        "advisory": None,
    }
    print(json.dumps(out))
    if decision in ("route-to-pool", "route-to-jam"):
        sys.exit(3)


def main():
    p = argparse.ArgumentParser(prog="shelf-match")
    sub = p.add_subparsers(required=True)
    pm = sub.add_parser("match")
    pm.add_argument("--item", required=True, help="the inbox item's filename/slug")
    pm.add_argument("--backlog", required=True, help="path to docs/step-1-ideas/backlog/")
    pm.add_argument("--parked", required=True, help="path to docs/step-1-ideas/parked/")
    pm.add_argument("--jams", required=True, help="path to docs/step-2-planning/ (live jam-* folders)")
    pm.set_defaults(fn=cmd_match)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
