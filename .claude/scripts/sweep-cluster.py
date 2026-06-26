#!/usr/bin/env python3
"""sweep-cluster.py — the DETERMINISTIC /sweep clustering + W11 gate-verdict floor (ADR-126, F9; SHR3-T5).

F9 BINDING (ADR-126 D-1) — ZERO LLM involvement in the decision. Two `/sweep` decisions that were LLM
inferences become deterministic here:
  - **cluster** — which inbox ideas group together (a coarse token-similarity partition over the LIVE inbox,
    folder-as-truth), the deterministic floor under § 2c's coarse `new-cluster` grain.
  - **gate** — which W11 verdict-validity gate (G1–G4, SKILL.md § 2d) deterministically fires on a proposed
    verdict, given live folder state (live jams for G1, content presence for G3).
The partition / gate verdict is THIS script's, never a model's. The only LLM role is **advisory-only** and
NEVER overrides `decision` — exactly `queue-order.py`'s discipline.

The no-guess contract (ADR-126 D-3) — this is the load-bearing boundary for this family. The fine
member/boundary partition and the *content-value* judgments that need real reading are LLM ceiling work
(SKILL.md § 2c: "fine member/boundary convergence is the in-skill convergence pass's job"). So:
  - `cluster` emits only the COARSE token-similarity grouping (a union-find over a high overlap floor) and
    ABSTAINS (a singleton stays its own group / a borderline edge is dropped) rather than guessing a fine
    boundary. The fine partition is drawn in the convergence pass by the LLM, exactly as § 2c mandates.
  - `gate` fires a verdict-MODIFY/BLOCK ONLY on a deterministic structural signal (G1 a live-jam topic
    match; G3 a structurally-thin stub by content-presence). A judgment-class check (is this *genuinely* a
    duplicate idea worth dropping — G2; are these *semantically* the same work — G4 content nuance) returns
    `abstain` and routes to the LLM ceiling. We never emit a confident gate verdict the structure can't back.

The `reason` field (ADR-126 D-2) is the script's OWN deterministic justification — the rule that fired
(e.g. "G1: topic 'flow-telemetry' matches live jam 'jam-flow-telemetry' (overlap 0.71 >= 0.66) -> MODIFY
new-cluster to ingest-to-jam").

folder-as-truth (ADR-126 D-4): cluster reads the LIVE inbox; gate reads live jams + the item's content.

Subcommands:
  cluster  --inbox DIR [--items CSV]                          # coarse token-similarity groups over the inbox
  gate     --verdict V --item FILE --jams DIR [--topic SLUG]  # which W11 gate (G1-G4) deterministically fires

`cluster` prints {"decision": [[file,...], ...], "reason": <str>, "confidence": "coarse", "advisory": null}
  — groups of >= 2; singletons are reported in `reason` as abstained (their own group).
`gate` prints {"decision": "OK"|"MODIFIED"|"BLOCKED"|"abstain", "gate": "G1"|"G3"|null, "verdict": <new|same>,
  "reason": <str>, "confidence": "high"|"low"|null, "advisory": null}. A MODIFIED/BLOCKED exits 3 (the
  deterministic flag) so the caller applies the gate disposition before the moves (§ 3).
"""
import json
import os
import re
import sys
import argparse

# Coarse clustering floor: an edge between two ideas exists when their slug-token Jaccard >= CLUSTER_THRESHOLD.
# A high floor keeps clustering COARSE (§ 2c) — borderline edges below the floor are DROPPED (abstained to the
# LLM convergence pass), never guessed into a group. Deterministic constant — NOT a model-tuned weight.
CLUSTER_THRESHOLD = 0.50
# Gate G1 jam-refork match floor (mirrors shelf-match's jam floor / § 2b fuzzy matching).
G1_JAM_THRESHOLD = 0.50
# Gate G3 thinness floor: a stub with fewer than G3_MIN_BODY_WORDS of body content (beyond the title) is a
# structurally-thin stub -> BLOCKED from graduation. Content presence, not length pedantry.
G3_MIN_BODY_WORDS = 12

_SKIP_NAMES = {"README.md", "INDEX.md"}
_PREFIX_RE = re.compile(r"^(?:DEFER-|FOLLOWUP-|ARCHIVED-|\d{4}-\d{2}-\d{2}-)+", re.IGNORECASE)
_JAM_PREFIX = "jam-"
_STOPWORDS = {"the", "a", "an", "and", "or", "of", "to", "for", "in", "on", "is", "be", "vs"}
# Verdicts that graduate an item out of the inbox toward planning/spec (G3's scope).
_GRADUATING_VERDICTS = {"promote", "delta-pool-for-spec", "ingest-to-jam"}
# Verdicts that fork a new cluster (G1's scope).
_FORKING_VERDICTS = {"new-cluster"}


def _die(msg, code=2):
    sys.stderr.write(f"sweep-cluster: {msg}\n")
    sys.exit(code)


def _normalize_slug(name):
    base = name[:-3] if name.endswith(".md") else name
    base = _PREFIX_RE.sub("", base)
    base = base.lower()
    base = re.sub(r"[^a-z0-9]+", "-", base).strip("-")
    return base


def _tokens(slug):
    return {t for t in slug.split("-") if t and t not in _STOPWORDS}


def _area_tag(slug):
    """ADDITIVE-ONLY clustering signal (SHR4-E3 / AC-019). The explicit `area:` of an inbox item is its
    `<area>-` slug prefix — the FIRST non-stopword token of the normalized slug (read from the same item
    shape `_tokens`/`_normalize_slug` use, no content read, fully deterministic). Returns the area string,
    or None when the slug has no usable leading token. This is a POSITIVE signal only: two items sharing an
    area get an ADDED union edge (cmd_cluster), and a different/absent area can NEVER block or drop a
    token-overlap edge — the abstain-to-ceiling discipline (ADR-126) is untouched."""
    for t in slug.split("-"):
        if t and t not in _STOPWORDS:
            return t
    return None


def _jaccard(a, b):
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def _inbox_items(inbox_dir, only):
    """Read the LIVE inbox tree (folder-as-truth, recursive) -> [(relpath, token_set, area)]. `only` filters
    to a named subset (csv of filenames/relpaths) if given. `area` is the item's `<area>-` slug prefix
    (SHR4-E3), an ADDITIVE-only clustering signal."""
    only_set = {o.strip() for o in only.split(",")} if only else None
    items = []
    if not os.path.isdir(inbox_dir):
        return items
    for root, _dirs, files in os.walk(inbox_dir):
        for fn in sorted(files):
            if not fn.endswith(".md") or fn in _SKIP_NAMES:
                continue
            rel = os.path.relpath(os.path.join(root, fn), inbox_dir)
            if only_set is not None and rel not in only_set and fn not in only_set:
                continue
            slug = _normalize_slug(fn)
            items.append((rel, _tokens(slug), _area_tag(slug)))
    items.sort(key=lambda t: t[0])
    return items


def cmd_cluster(a):
    items = _inbox_items(a.inbox, a.items)
    n = len(items)
    # --- deterministic union-find over the high-floor overlap graph (no LLM, no randomness) ---
    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(x, y):
        rx, ry = find(x), find(y)
        if rx != ry:
            parent[max(rx, ry)] = min(rx, ry)

    edges = 0
    area_edges = 0
    for i in range(n):
        for j in range(i + 1, n):
            # Token-overlap edge — fires on its OWN whenever Jaccard clears the floor, regardless of area.
            token_edge = _jaccard(items[i][1], items[j][1]) >= CLUSTER_THRESHOLD
            # ADDITIVE area edge (SHR4-E3 / AC-019): a POSITIVE signal that JOINS two items sharing a present,
            # matching `area:` tag. This can only ADD an edge — it NEVER gates, ANDs, or vetoes the token
            # edge. A different or absent area does NOT block a strong token-overlap edge (the additive-only
            # invariant; the abstain-to-ceiling discipline of ADR-126 is untouched — untagged items still
            # abstain exactly as before). No randomness, no LLM.
            area_i, area_j = items[i][2], items[j][2]
            area_edge = area_i is not None and area_i == area_j
            if token_edge:
                union(i, j)
                edges += 1
            if area_edge:
                union(i, j)
                area_edges += 1

    groups = {}
    for i in range(n):
        groups.setdefault(find(i), []).append(items[i][0])
    clustered = sorted((sorted(g) for g in groups.values() if len(g) >= 2), key=lambda g: g[0])
    singletons = sorted(g[0] for g in groups.values() if len(g) == 1)

    reason = (
        f"coarse union-find over {n} items, {edges} token-overlap edge(s) at overlap floor "
        f"{CLUSTER_THRESHOLD} + {area_edges} additive area-tag edge(s): {len(clustered)} cluster(s); "
        f"{len(singletons)} singleton(s) abstained (own group, fine boundary deferred to the LLM "
        f"convergence pass per § 2c)"
    )
    out = {"decision": clustered, "reason": reason, "confidence": "coarse", "advisory": None}
    print(json.dumps(out))


def _jam_slugs(jams_dir):
    items = []
    if not os.path.isdir(jams_dir):
        return items
    for dn in sorted(os.listdir(jams_dir)):
        if dn.startswith(_JAM_PREFIX) and os.path.isdir(os.path.join(jams_dir, dn)):
            items.append((dn, _tokens(_normalize_slug(dn[len(_JAM_PREFIX):]))))
    return items


def _body_word_count(item_path):
    """Content-presence measure for G3: count body words EXCLUDING the first heading/title line. Missing
    file -> 0 (structurally thin)."""
    if not os.path.isfile(item_path):
        return 0
    try:
        with open(item_path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as e:
        _die(f"unreadable item {item_path}: {e}")
    body = []
    seen_title = False
    for ln in lines:
        s = ln.strip()
        if not s:
            continue
        if not seen_title and s.startswith("#"):
            seen_title = True
            continue
        # strip markdown/list punctuation for a word count
        body.extend(re.findall(r"[A-Za-z0-9]+", s))
    return len(body)


def cmd_gate(a):
    verdict = a.verdict.strip()
    topic_slug = a.topic if a.topic else _normalize_slug(os.path.basename(a.item))
    topic_tokens = _tokens(topic_slug)

    # --- G1: never re-fork a live jam (deterministic topic match) ---
    if verdict in _FORKING_VERDICTS:
        best_jam, best_score = None, 0.0
        for dn, toks in _jam_slugs(a.jams):
            score = _jaccard(topic_tokens, toks)
            if score > best_score:
                best_jam, best_score = dn, score
        if best_jam is not None and best_score >= G1_JAM_THRESHOLD:
            out = {
                "decision": "MODIFIED", "gate": "G1", "verdict": "ingest-to-jam",
                "reason": (
                    f"G1: topic '{topic_slug}' matches live jam '{best_jam}' "
                    f"(overlap {round(best_score, 2)} >= {G1_JAM_THRESHOLD}) -> MODIFY new-cluster to "
                    f"ingest-to-jam (never re-fork a live jam)"
                ),
                "confidence": "high", "advisory": None,
            }
            print(json.dumps(out))
            sys.exit(3)
        # No live-jam match: G1 does not fire. New-cluster is structurally OK (grain is § 2c's job, abstained).
        out = {
            "decision": "OK", "gate": "G1", "verdict": "new-cluster",
            "reason": f"G1: no live jam matches topic '{topic_slug}' >= {G1_JAM_THRESHOLD} — fork allowed",
            "confidence": "high", "advisory": None,
        }
        print(json.dumps(out))
        return

    # --- G3: don't graduate thin stubs (deterministic content-presence) ---
    if verdict in _GRADUATING_VERDICTS:
        words = _body_word_count(a.item)
        if words < G3_MIN_BODY_WORDS:
            out = {
                "decision": "BLOCKED", "gate": "G3", "verdict": "keep",
                "reason": (
                    f"G3: '{os.path.basename(a.item)}' body has {words} content words "
                    f"(< {G3_MIN_BODY_WORDS}) — structurally thin stub, BLOCKED from graduation -> keep"
                ),
                "confidence": "high", "advisory": None,
            }
            print(json.dumps(out))
            sys.exit(3)
        out = {
            "decision": "OK", "gate": "G3", "verdict": verdict,
            "reason": (
                f"G3: '{os.path.basename(a.item)}' body has {words} content words "
                f"(>= {G3_MIN_BODY_WORDS}) — substantial enough to graduate"
            ),
            "confidence": "high", "advisory": None,
        }
        print(json.dumps(out))
        return

    # --- G2 (drop-preservation) / G4 (consolidate-related) are content-NUANCE judgments: abstain (no-guess) ---
    # Whether a drop genuinely loses a unique idea (G2) or whether two items are SEMANTICALLY the same work
    # (G4) needs real reading — the LLM ceiling, not the structural floor. Per ADR-126 D-3 we abstain rather
    # than emit a confident gate verdict the structure cannot back.
    out = {
        "decision": "abstain", "gate": None, "verdict": verdict,
        "reason": (
            f"verdict '{verdict}' carries no deterministic structural gate (G2/G4 are content-nuance "
            f"judgments) — route to the LLM ceiling (no-guess, ADR-126 D-3)"
        ),
        "confidence": "low", "advisory": None,
    }
    print(json.dumps(out))


def main():
    p = argparse.ArgumentParser(prog="sweep-cluster")
    sub = p.add_subparsers(required=True)

    pc = sub.add_parser("cluster")
    pc.add_argument("--inbox", required=True, help="path to the live docs/step-1-ideas/ tree")
    pc.add_argument("--items", default=None, help="optional csv of filenames/relpaths to restrict the partition to")
    pc.set_defaults(fn=cmd_cluster)

    pg = sub.add_parser("gate")
    pg.add_argument("--verdict", required=True, help="the proposed /sweep verdict (new-cluster/promote/...)")
    pg.add_argument("--item", required=True, help="path to the inbox item the verdict applies to")
    pg.add_argument("--jams", required=True, help="path to docs/step-2-planning/ (live jam-* folders) for G1")
    pg.add_argument("--topic", default=None, help="explicit cluster topic slug for G1 (default: item slug)")
    pg.set_defaults(fn=cmd_gate)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
