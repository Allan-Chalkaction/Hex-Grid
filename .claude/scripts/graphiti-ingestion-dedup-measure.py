#!/usr/bin/env python3
"""graphiti-ingestion-dedup-measure — W2 dedup MEASUREMENT spike (graphiti-ingestion-strategy, GIS-T6).

A READ-ONLY corpus-analysis instrument. It measures the actual near-duplicate VOLUME that survives
graphiti-core's edge-resolution path (`resolve_extracted_edge` / `dedupe_edges`) on the LIVE neo4j
corpus, then emits a binding `Decision: BUILD|DEFER` line per ADR-096 §2.

  python3 graphiti-ingestion-dedup-measure.py                          # print the measurement
  python3 graphiti-ingestion-dedup-measure.py --emit-findings <path>   # also write the findings doc

WHAT THIS IS NOT (binding scope guards — ADR-096 §2, GIS-T6 prompt Gotchas):
  - NOT a host-side dedup FILTER in front of `add_episode`. The deliverable is an instrument + a doc;
    no production write-path code path is introduced. (A BUILD verdict only spawns a follow-on epic.)
  - NOT a token-telemetry COST join. The ADR-074 `lane:"write"` sink is empirically dead for the
    deliberate-write path (graphiti-wave2-measure.py lines 14-21): `graphiti_write.py`'s `_INNER` builds
    its own `AnthropicClient` and does NOT route through the Gemini client ADR-074's telemetry wraps,
    so the sink carries zero matching records. We measure VOLUME via neo4j, never COST via telemetry.

THE METRIC (precisely defined — see findings "Methodology"):
  A near-duplicate is a pair of persisted `:RELATES_TO` edges within the same `group_id` whose
  1024-dim `fact_embedding` cosine similarity is >= NEAR_DUP_THRESH. Because these edges are READ from
  the persisted graph, they have ALREADY passed through graphiti-core's `resolve_extracted_edge` /
  `dedupe_edges` resolution at write time. So any near-dup we count is a near-dup graphiti-core did NOT
  collapse — which is exactly the "already captured: no" signal the two-pronged decision needs.

THE "ALREADY CAPTURED BY GRAPHITI-CORE" CHECK (the load-bearing guard — ADR-096 §2, AC-006):
  We also count EXACT-text duplicate facts (normalized). graphiti-core's hash/normalization dedup
  collapses exact restatements; whatever exact-dup volume remains is the residue its exact path missed,
  and the semantic near-dup volume is what its embedding-cosine path (`dedupe_edges`) let through. We
  report both against the post-resolution edge count so a DEFER is justified when the library already
  collapsed the reducible volume.

THE DECISION (two-pronged — ADR-096 §2, AC-007):
  BUILD iff (reducible-near-dup volume is worth trimming) AND (graphiti-core isn't already capturing it).
  There is NO pre-set numeric threshold (ADR-096 §2: operator sets the bar at W2 close against this
  measured number). The script reports the number + the already-captured check and states the implied
  verdict per the binding rule; absent a corpus, it defaults to DEFER without fabricating a number.

Reuses the docker-exec / in-container-venv neo4j subprocess pattern from
`core/scripts/graphiti-wave2-measure.py::neo4j_metrics()` (lines 101-143) — the precedent is read-and-
reused, never modified.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Container / env conventions inherited verbatim from graphiti-wave2-measure.py (lines 45-46).
# ADR-096 §2 resolves the stale `docker-neo4j-1` brief drift in favor of the MCP container default.
MCP = os.environ.get("GRAPHITI_MCP_CONTAINER", "docker-graphiti-mcp-1")
PYV = "/app/mcp/.venv/bin/python"

# The live capture partition W1's tagged writes produced (the read target).
GROUP_ID = os.environ.get("GRAPHITI_DEDUP_GROUP", "claude-infra-v2")

# A near-duplicate is a within-group fact-embedding cosine >= this. 0.92 is a deliberately conservative
# semantic-near-dup bar: well above incidental topical overlap, below exact restatement (~1.0). Documented
# so the operator can re-interpret the number at W2 close (ADR-096 §2 — no pre-set threshold).
NEAR_DUP_THRESH = float(os.environ.get("GRAPHITI_NEAR_DUP_THRESH", "0.92"))

# Pairwise cosine is O(n^2). Cap the scan to a documented representative subset to bound runtime under the
# docker-exec timeout=60 (AC-014). At the current corpus (~1512 edges) the full scan runs in ~38s, so the
# default cap covers the whole partition; larger corpora deterministically sample the most-recent N.
MAX_PAIRWISE_EDGES = int(os.environ.get("GRAPHITI_DEDUP_MAX_EDGES", "2000"))


def container_present() -> bool:
    """True iff the MCP container is running (mirrors graphiti-wave2-measure.py's docker ps guard)."""
    try:
        out = subprocess.run(["docker", "ps", "--format", "{{.Names}}"],
                             capture_output=True, text=True, timeout=15).stdout
    except (subprocess.SubprocessError, OSError):
        return False
    return out.find(MCP) >= 0


def measure_dedup(group_id: str) -> dict:
    """One docker-exec READ: near-dup volume + exact-dup volume + post-resolution counts for one group.

    READ-only (MATCH ... RETURN only); inspection, never a write. Returns {} if the container is absent or
    the exec fails — the caller treats {} as 'no measurement' and defaults to DEFER (AC-008)."""
    if not container_present():
        return {}

    # The in-container snippet. Every Cypher is MATCH ... RETURN (read-only — AC-003). Credentials come
    # from the container's own NEO4J_* env (no host-side hardcoded password — AC-009).
    snippet = r'''
import os, json, math, time
from neo4j import GraphDatabase

group_id = os.environ["DEDUP_GROUP"]
thresh = float(os.environ["DEDUP_THRESH"])
max_edges = int(os.environ["DEDUP_MAX_EDGES"])

d = GraphDatabase.driver(os.environ["NEO4J_URI"],
                         auth=(os.environ["NEO4J_USER"], os.environ["NEO4J_PASSWORD"]))
out = {}
with d.session() as s:
    # --- Post-resolution corpus counts (what survived resolve_extracted_edge at write time) ---
    out["episodic"] = s.run(
        "MATCH (n:Episodic) WHERE n.group_id=$g RETURN count(n) AS c", g=group_id).single()["c"]
    out["entities"] = s.run(
        "MATCH (n:Entity) WHERE n.group_id=$g RETURN count(n) AS c", g=group_id).single()["c"]
    out["edges"] = s.run(
        "MATCH ()-[r:RELATES_TO]->() WHERE r.group_id=$g RETURN count(r) AS c", g=group_id).single()["c"]

    # --- Already-captured prong A: EXACT-text duplicate facts graphiti-core did NOT collapse ---
    # (normalized lowercase/trim). Each surviving exact-dup is residue past the hash/normalization path.
    exact = s.run(
        "MATCH ()-[r:RELATES_TO]->() WHERE r.group_id=$g "
        "WITH toLower(trim(r.fact)) AS f, count(*) AS c WHERE c > 1 "
        "RETURN count(f) AS dupgroups, coalesce(sum(c),0) AS dupedges", g=group_id).single()
    out["exact_dup_groups"] = exact["dupgroups"]
    out["exact_dup_edges"] = exact["dupedges"]

    # --- Reducible prong B: SEMANTIC near-dup pairs the embedding-cosine path (dedupe_edges) let through ---
    # Read facts + embeddings (deterministic order; cap to a representative subset for the O(n^2) scan).
    rows = s.run(
        "MATCH ()-[r:RELATES_TO]->() "
        "WHERE r.group_id=$g AND r.fact_embedding IS NOT NULL "
        "RETURN r.fact AS f, r.fact_embedding AS e ORDER BY r.created_at DESC, r.uuid "
        "LIMIT $lim", g=group_id, lim=max_edges).data()

embs = [r["e"] for r in rows]
out["sample_n"] = len(embs)
out["full_scan"] = (len(embs) >= out["edges"])  # True iff the cap covered the whole partition

# L2-normalize once, then pairwise cosine = dot product.
def _norm(v):
    m = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / m for x in v]

t0 = time.time()
ne = [_norm(v) for v in embs]
n = len(ne)
near_pairs = 0
edges_in_near = set()
top_examples = []
for i in range(n):
    a = ne[i]
    for j in range(i + 1, n):
        b = ne[j]
        cos = 0.0
        for k in range(len(a)):
            cos += a[k] * b[k]
        if cos >= thresh:
            near_pairs += 1
            edges_in_near.add(i)
            edges_in_near.add(j)
            if len(top_examples) < 8:
                top_examples.append({"a": rows[i]["f"][:140], "b": rows[j]["f"][:140],
                                     "cos": round(cos, 4)})
out["near_dup_pairs"] = near_pairs
out["edges_in_near_dup"] = len(edges_in_near)
out["scan_seconds"] = round(time.time() - t0, 1)
out["examples"] = top_examples
out["thresh"] = thresh

print(json.dumps(out))
d.close()
'''
    try:
        proc = subprocess.run(
            ["docker", "exec",
             "-e", f"DEDUP_GROUP={group_id}",
             "-e", f"DEDUP_THRESH={NEAR_DUP_THRESH}",
             "-e", f"DEDUP_MAX_EDGES={MAX_PAIRWISE_EDGES}",
             "-w", "/app/mcp", MCP, PYV, "-c", snippet],
            capture_output=True, text=True, timeout=120,  # the O(n^2) scan runs in-container; allow headroom
        )
    except (subprocess.SubprocessError, OSError):
        return {}
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return {}


def decide(m: dict) -> tuple[str, str]:
    """Transparent two-pronged decision rule (ADR-096 §2). Returns (decision_token, rationale).

    BUILD iff (reducible near-dup volume is worth trimming) AND (graphiti-core isn't already capturing it).
    No pre-set threshold — the operator sets the bar at W2 close against the measured number; this function
    states the IMPLIED verdict and shows its work. Absent a measurement, default DEFER (AC-008)."""
    if not m or not m.get("edges"):
        return ("DEFER",
                "neo4j unreachable / corpus empty — no near-duplicate volume could be measured. "
                "Per ADR-096 §2 the dedup fork stays deferred absent measured evidence; this is a valid "
                "DEFER-with-unavailability, not a failure. Do NOT fabricate a number.")

    edges = m["edges"]
    near = m.get("edges_in_near_dup", 0)
    near_pairs = m.get("near_dup_pairs", 0)
    exact = m.get("exact_dup_edges", 0)
    rate = (near / edges) if edges else 0.0

    # Prong B (already-captured): these near-dups were READ from the persisted graph, so they already
    # survived resolve_extracted_edge / dedupe_edges at write time. A non-zero near-dup count IS the
    # "graphiti-core did NOT capture this" signal. Exact-dup residue (prong A) corroborates: if exact-text
    # restatements also slipped through, the library's hash path is leaving collapsible volume too.
    already_captured = (near_pairs == 0)

    # Prong A (worth trimming): a one-shot spike has no operator threshold yet, so the rule reports the
    # rate and applies a transparent "negligible" floor: a reducible rate at or below the floor is not
    # worth a data-loss-class host-side filter. The floor is documented, not a hidden ">10%".
    NEGLIGIBLE_FLOOR = 0.02  # <=2% of surviving edges is not worth a second source of truth fighting the lib
    worth_trimming = rate > NEGLIGIBLE_FLOOR

    captured_str = ("YES — graphiti-core's resolution already collapsed the duplicates (zero survived)"
                    if already_captured else
                    f"NO — {near} of {edges} surviving edges ({rate:.1%}) form {near_pairs} near-dup "
                    f"pair(s) that passed THROUGH resolve_extracted_edge uncaught; exact-text residue: "
                    f"{exact} edge(s)")

    if worth_trimming and not already_captured:
        return ("BUILD",
                f"Reducible near-dup volume {near}/{edges} ({rate:.1%}) exceeds the negligible floor "
                f"({NEGLIGIBLE_FLOOR:.0%}) AND is NOT already captured by graphiti-core "
                f"({captured_str}). Both prongs met → a host-side dedup pass would trim real residue the "
                f"library leaves. Operator sets the final bar at W2 close against this number.")
    # Either prong fails → DEFER.
    if already_captured:
        why = (f"already-captured prong FAILS: graphiti-core's resolution left zero near-duplicates "
               f"(near-dup rate 0.0%). Nothing to trim host-side.")
    else:
        why = (f"worth-trimming prong FAILS: reducible near-dup rate {rate:.1%} "
               f"({near}/{edges}) is at/below the negligible floor ({NEGLIGIBLE_FLOOR:.0%}); a "
               f"data-loss-class host-side filter is not justified against this volume. "
               f"Already-captured check: {captured_str}.")
    return ("DEFER",
            f"{why} Per ADR-096 §2 BUILD requires BOTH prongs; with one unmet the fork stays shelved "
            f"with evidence behind it (a DEFER is an equally successful spike outcome).")


def render_findings(m: dict, decision: str, rationale: str) -> str:
    """Findings doc — methodology -> measured numbers -> rationale -> `Decision:` line LAST (AC-007)."""
    available = bool(m and m.get("edges"))

    if not available:
        measured = ("> **neo4j unreachable / corpus empty.** No measurement was taken. Per AC-008 this "
                    "records unavailability and defaults the verdict to DEFER rather than fabricating a "
                    f"number. (Container target: `{MCP}`; partition: `{GROUP_ID}`.)\n")
        already = ("Not evaluable — no corpus reached. The already-captured-by-graphiti-core check "
                   "requires a live post-resolution edge count.\n")
        sample_line = "n/a (corpus unavailable)"
        examples_block = "_n/a — no corpus reached._"
    else:
        edges = m["edges"]
        near = m.get("edges_in_near_dup", 0)
        near_pairs = m.get("near_dup_pairs", 0)
        exact_edges = m.get("exact_dup_edges", 0)
        exact_groups = m.get("exact_dup_groups", 0)
        rate = (near / edges) if edges else 0.0
        sample_n = m.get("sample_n", 0)
        full = m.get("full_scan", False)
        scan_s = m.get("scan_seconds", "?")

        measured = (
            f"| metric | value |\n"
            f"|---|---|\n"
            f"| partition (`group_id`) | `{GROUP_ID}` |\n"
            f"| Episodic nodes (sample size N, episodes) | {m.get('episodic', '?')} |\n"
            f"| Entity nodes (post-resolution) | {m.get('entities', '?')} |\n"
            f"| `:RELATES_TO` edges (post-resolution) | {edges} |\n"
            f"| edges scanned for near-dup (subset bound) | {sample_n}"
            f"{' (full partition)' if full else ' (most-recent subset — AC-014)'} |\n"
            f"| cosine threshold | {m.get('thresh', NEAR_DUP_THRESH)} |\n"
            f"| **near-dup pairs (semantic)** | **{near_pairs}** |\n"
            f"| **edges participating in a near-dup** | **{near}** of {edges} (**{rate:.1%}**) |\n"
            f"| exact-text duplicate facts (groups / edges) | {exact_groups} / {exact_edges} |\n"
            f"| pairwise scan time | {scan_s}s |\n"
        )

        already_captured = (near_pairs == 0)
        already = (
            f"- **Host-measured near-dup count:** {near} edges ({near_pairs} pairs) at cosine "
            f"≥ {m.get('thresh', NEAR_DUP_THRESH)} within `{GROUP_ID}`.\n"
            f"- **graphiti-core post-resolution edge count:** {edges} `:RELATES_TO` edges — these are the "
            f"edges that SURVIVED `resolve_extracted_edge` / `dedupe_edges` at write time.\n"
            f"- **Inference — already captured by graphiti-core:** "
            f"**{'YES' if already_captured else 'NO'}.** "
            + ("graphiti-core's resolution left zero near-duplicates in the persisted graph; its internal "
               "embedding/normalization dedup is already collapsing the reducible volume, so there is "
               "nothing for a host-side filter to trim.\n"
               if already_captured else
               f"the {near} near-dup edges were READ from the persisted graph, meaning they each passed "
               f"THROUGH graphiti-core's resolution UNCAUGHT. The library's exact-hash path also left "
               f"{exact_edges} exact-text duplicate edge(s) ({exact_groups} group(s)). The residue is real "
               f"and host-reducible.\n"))

        sample_line = (f"{sample_n} of {edges} `:RELATES_TO` edges"
                       f"{' (full partition)' if full else ' (most-recent subset)'} in `{GROUP_ID}`")

        ex = m.get("examples", [])
        if ex:
            examples_block = "\n".join(
                f"- cos `{e['cos']}`:\n  - A: {e['a']}\n  - B: {e['b']}" for e in ex)
        else:
            examples_block = "_No near-dup pairs at the threshold — none to exhibit._"

    return f"""# W2 — Graphiti Ingestion Dedup MEASUREMENT Findings

_graphiti-ingestion-strategy epic · Wave 2 (`wave-2-dedup-measurement`, GIS-T6) · generated by_
_`core/scripts/graphiti-ingestion-dedup-measure.py`. Governing decision: **ADR-096 §2** (gate dedup on_
_measured evidence)._

## What this spike is (and is NOT)

This is a **measurement-only** corpus-analysis instrument. It builds **no host-side dedup filter** in
front of `add_episode` and runs nothing in the production write rail (ADR-096 §2). It measures the
near-duplicate VOLUME surviving graphiti-core's resolution and emits a binding `Decision: BUILD|DEFER`
line. A BUILD verdict only authorizes a *separate* follow-on epic; a DEFER is an equally successful
outcome (the fork stays shelved with evidence behind it).

It does **NOT** attempt the ADR-074 token-telemetry cost join: that sink is empirically dead for the
deliberate-write path (`graphiti_write.py`'s `_INNER` builds its own `AnthropicClient`, bypassing the
Gemini client ADR-074's telemetry wraps — see `graphiti-wave2-measure.py` lines 14-21). We measure
VOLUME via neo4j, never COST via telemetry.

## Methodology

- **Corpus / partition:** the LIVE neo4j graph in container `{MCP}`, partition `group_id={GROUP_ID}`
  (the live capture group W1's tagged writes produced). Reached via the docker-exec / in-container-venv
  python subprocess pattern reused from `core/scripts/graphiti-wave2-measure.py::neo4j_metrics()`
  (lines 101-143). Every Cypher is read-only `MATCH ... RETURN`.
- **Sample size / subset bound:** {sample_line}. Pairwise cosine is O(n²); the scan is capped to a
  representative most-recent subset (`GRAPHITI_DEDUP_MAX_EDGES`, default {MAX_PAIRWISE_EDGES}) to bound
  runtime (AC-014). At the current corpus the cap covers the whole partition.
- **Near-duplicate definition (precise):** a pair of persisted `:RELATES_TO` edges within the same
  `group_id` whose 1024-dim `fact_embedding` cosine similarity is ≥ the threshold ({NEAR_DUP_THRESH} by
  default). Because the edges are READ from the persisted graph, they have **already passed through**
  graphiti-core's `resolve_extracted_edge` / `dedupe_edges` resolution at write time — so any near-dup
  counted here is one the library did **not** collapse.
- **Already-captured check (two prongs):** (A) EXACT-text duplicate facts (normalized) that survived the
  library's hash/normalization path; (B) SEMANTIC near-dup pairs that survived its embedding-cosine path.
  Both are reported against the post-resolution edge count so a DEFER is justified when graphiti-core
  already collapsed the reducible volume.

## Measured numbers

{measured}

## Already captured by graphiti-core?

{already}

### Near-dup examples (top pairs by cosine)

{examples_block}

## Decision rationale

{rationale}

The binding rule (ADR-096 §2): BUILD **iff** the reducible near-dup volume is worth trimming **AND**
graphiti-core's internal dedup is not already capturing it; otherwise DEFER. There is no pre-set numeric
threshold — the operator sets the final bar at W2 close against the measured number above. This spike
reports the number and the already-captured check and states the implied verdict; it does **not** build
the filter.

Decision: {decision}
"""


def main() -> int:
    ap = argparse.ArgumentParser(
        description="W2 dedup MEASUREMENT spike — measures near-dup volume on the live neo4j corpus and "
                    "emits a binding Decision: BUILD|DEFER line (ADR-096 §2). Measurement only; builds no "
                    "dedup filter.")
    ap.add_argument("--emit-findings", metavar="PATH", default=None,
                    help="write the findings document (with the binding Decision line) to PATH")
    args = ap.parse_args()

    m = measure_dedup(GROUP_ID)
    decision, rationale = decide(m)

    if not m or not m.get("edges"):
        # Graceful degradation (AC-008): clear message, non-crash exit, DEFER default — no fabricated number.
        print(f"neo4j unreachable — no measurement. Container `{MCP}` absent or empty corpus "
              f"(partition `{GROUP_ID}`).")
        print(f"Decision  — {decision} (default; corpus unavailable, no number fabricated)")
    else:
        edges = m["edges"]
        near = m.get("edges_in_near_dup", 0)
        rate = (near / edges) if edges else 0.0
        print(f"Partition — group_id={GROUP_ID}  (N={m.get('episodic', '?')} episodes, "
              f"{m.get('entities', '?')} entities, {edges} edges; sample={m.get('sample_n', '?')} edges)")
        print(f"Near-dup  — {m.get('near_dup_pairs', 0)} pairs / {near} edges "
              f"({rate:.1%}) at cosine >= {m.get('thresh', NEAR_DUP_THRESH)}  | "
              f"exact-text dups: {m.get('exact_dup_edges', 0)} edges")
        print(f"Decision  — {decision}")

    if args.emit_findings:
        out = render_findings(m, decision, rationale)
        path = Path(args.emit_findings)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(out, encoding="utf-8")
        print(f"findings -> {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
