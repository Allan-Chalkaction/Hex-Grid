#!/usr/bin/env python3
"""idea-dedup.py — the DETERMINISTIC inbox-duplicate floor for an incoming idea (ADR-126, F9; SHR3-T5).

F9 BINDING (ADR-126 D-1) — ZERO LLM involvement in the decision. This script answers ONE question
deterministically: "is an incoming idea a duplicate of an existing inbox item?" — purely from a normalized
slug/token comparison against the LIVE `docs/step-1-ideas/` tree (folder-as-truth). The verdict is THIS
script's, never a model's. The only LLM role is **advisory-only** (the caller may populate `advisory` with a
"these read related" hint) and NEVER overrides the computed `decision` — exactly `queue-order.py`'s discipline.

The no-guess contract (ADR-126 D-3): on an indeterminate input — a fuzzy near-match that is NOT a strong
structural duplicate — this script **abstains** (`decision: "abstain"`) rather than emitting a probabilistic
"probably a dupe" call. The LLM ceiling (the `/sweep` G2/G4 judgment) takes the abstained cases. The script
asserts a `duplicate` verdict ONLY on a strong deterministic signal:
  - **exact** — the normalized slug is byte-identical to an existing item's normalized slug, OR
  - **strong** — the Jaccard token overlap of the two slugs is >= DUPLICATE_THRESHOLD (a high floor).
Anything in the AMBIGUOUS band (ABSTAIN_THRESHOLD <= overlap < DUPLICATE_THRESHOLD) is **abstain** — the
deliberate no-guess zone. Below ABSTAIN_THRESHOLD it is a confident `unique`.

The `reason` field (ADR-126 D-2) is the script's OWN deterministic justification string — the rule that
produced `decision` (e.g. "exact slug match with <file>" / "token overlap 0.83 >= 0.75 with <file>" /
"best overlap 0.55 in abstain band [0.40,0.75)"), NOT a prose blurb a model would write.

folder-as-truth (ADR-126 D-4): the candidate set is read from the LIVE filesystem
(`docs/step-1-ideas/**/*.md`, recursive, README/INDEX excluded), never session memory.

Subcommands:
  check  --inbox DIR --slug SLUG [--exclude FILE]   # is SLUG a duplicate of an existing inbox item?

`check` prints a single JSON object: {"decision": "duplicate"|"unique"|"abstain", "reason": <str>,
"confidence": "exact"|"high"|"low"|null, "advisory": null}. A "duplicate" verdict exits 3 (the deterministic
flag, mirroring queue-order.py's conflict exit) so the `/sweep` caller can route to G2/G4 rather than re-mint.
"""
import json
import os
import re
import sys
import argparse

# Token-overlap floors (Jaccard over normalized slug tokens). A strong structural duplicate must clear
# DUPLICATE_THRESHOLD; the band [ABSTAIN_THRESHOLD, DUPLICATE_THRESHOLD) is the no-guess ABSTAIN zone; below
# ABSTAIN_THRESHOLD is a confident `unique`. These are deterministic constants — NOT model-tuned weights.
DUPLICATE_THRESHOLD = 0.75
ABSTAIN_THRESHOLD = 0.40

# Filenames that are not captured ideas (generated / structural) and are excluded from the candidate set.
_SKIP_NAMES = {"README.md", "INDEX.md"}
# Stage prefixes stripped before slug comparison so DEFER-/FOLLOWUP-/date-prefixed variants of the same idea
# compare equal on their topical slug (the prefix is stage memory, not topic).
_PREFIX_RE = re.compile(r"^(?:DEFER-|FOLLOWUP-|\d{4}-\d{2}-\d{2}-)+", re.IGNORECASE)
_STOPWORDS = {"the", "a", "an", "and", "or", "of", "to", "for", "in", "on", "is", "be", "vs"}


def _die(msg, code=2):
    sys.stderr.write(f"idea-dedup: {msg}\n")
    sys.exit(code)


def _normalize_slug(name):
    """Deterministic slug normalization: drop a `.md`, strip stage prefixes, lowercase, kebab-collapse."""
    base = name[:-3] if name.endswith(".md") else name
    base = _PREFIX_RE.sub("", base)
    base = base.lower()
    base = re.sub(r"[^a-z0-9]+", "-", base).strip("-")
    return base


def _tokens(slug):
    """Deterministic token set: split the normalized slug on `-`, drop stopwords + empties."""
    return {t for t in slug.split("-") if t and t not in _STOPWORDS}


def _jaccard(a, b):
    if not a or not b:
        return 0.0
    inter = len(a & b)
    union = len(a | b)
    return inter / union if union else 0.0


def _load_inbox(inbox_dir, exclude_norm):
    """Read the LIVE inbox tree (folder-as-truth) -> list of (relpath, normalized_slug, token_set).

    Recursive over `docs/step-1-ideas/**/*.md`; skips README/INDEX and the excluded self-file. Missing dir
    -> empty candidate set (a benign empty inbox, not an error)."""
    items = []
    if not os.path.isdir(inbox_dir):
        return items
    for root, _dirs, files in os.walk(inbox_dir):
        for fn in sorted(files):
            if not fn.endswith(".md") or fn in _SKIP_NAMES:
                continue
            rel = os.path.relpath(os.path.join(root, fn), inbox_dir)
            norm = _normalize_slug(fn)
            if norm == exclude_norm and exclude_norm:
                continue
            items.append((rel, norm, _tokens(norm)))
    items.sort(key=lambda t: t[0])
    return items


def cmd_check(a):
    incoming_norm = _normalize_slug(a.slug)
    exclude_norm = _normalize_slug(a.exclude) if a.exclude else ""
    incoming_tokens = _tokens(incoming_norm)
    candidates = _load_inbox(a.inbox, exclude_norm)

    # --- deterministic duplicate math (no LLM, no randomness) ---
    # 1. Exact normalized-slug match -> duplicate (the strongest signal).
    exact = next((rel for rel, norm, _t in candidates if norm == incoming_norm and incoming_norm), None)
    if exact is not None:
        decision, confidence = "duplicate", "exact"
        reason = f"exact normalized-slug match with '{exact}' (slug '{incoming_norm}')"
    else:
        # 2. Best token-overlap against the live candidate set.
        best_rel, best_score = None, 0.0
        for rel, _norm, toks in candidates:
            score = _jaccard(incoming_tokens, toks)
            if score > best_score:
                best_rel, best_score = rel, score
        rounded = round(best_score, 2)
        if best_rel is not None and best_score >= DUPLICATE_THRESHOLD:
            decision, confidence = "duplicate", "high"
            reason = f"token overlap {rounded} >= {DUPLICATE_THRESHOLD} with '{best_rel}'"
        elif best_rel is not None and best_score >= ABSTAIN_THRESHOLD:
            # no-guess: the ambiguous band -> abstain, never a probabilistic 'duplicate'.
            decision, confidence = "abstain", "low"
            reason = (
                f"best overlap {rounded} in abstain band "
                f"[{ABSTAIN_THRESHOLD},{DUPLICATE_THRESHOLD}) with '{best_rel}' — defer to LLM ceiling"
            )
        else:
            decision, confidence = "unique", "high"
            top = f" (best {rounded} with '{best_rel}')" if best_rel is not None else " (empty inbox)"
            reason = f"no candidate overlap >= {ABSTAIN_THRESHOLD}{top}"

    out = {"decision": decision, "reason": reason, "confidence": confidence, "advisory": None}
    print(json.dumps(out))
    if decision == "duplicate":
        sys.exit(3)


def main():
    p = argparse.ArgumentParser(prog="idea-dedup")
    sub = p.add_subparsers(required=True)
    pc = sub.add_parser("check")
    pc.add_argument("--inbox", required=True, help="path to the live docs/step-1-ideas/ tree")
    pc.add_argument("--slug", required=True, help="the incoming idea's filename/slug")
    pc.add_argument("--exclude", default=None, help="a filename to exclude from candidates (the self-file)")
    pc.set_defaults(fn=cmd_check)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
