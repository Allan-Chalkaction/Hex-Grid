#!/usr/bin/env python3
"""graphiti-wave2-measure — typed-vs-freeform A/B measurement (graphiti-cost-efficiency Wave 2, T5).

Computes the three deltas between the ab-wave2-typed-* and ab-wave2-freeform-* partitions written by
graphiti-wave2-ab.py, and emits the findings document with the binding Decision line.

  (a) Recall@k delta   — per-case + overall recall@k, via the UNMODIFIED core/scripts/graphiti-read.py
                         recency Cypher (the comparability anchor; Wave 0 §5.4). Read path is invoked
                         by subprocess — NEVER an inline Cypher (AC-022).
  (b) Entity-not-found rate — fraction of episodes that yielded ZERO extracted Entity nodes, per arm.
                         CHOSEN CRITERION (Open Question 4): a DIRECT neo4j signal (episodes with no
                         extracted entity), used because the telemetry-based criterion is INFEASIBLE
                         for this write path — see (c).
  (c) Token-per-episode delta — the spec's telemetry-join (ADR-074 sink) is INFEASIBLE here: the
                         deliberate-write path (graphiti_write.py _INNER) builds its OWN AnthropicClient
                         and does NOT route through the Gemini client that ADR-074's telemetry wraps, so
                         the sink carries ZERO ab-wave2 records. The script confirms that empirically and
                         reports the available extraction-yield COST PROXY from neo4j: entities + facts
                         extracted per episode, per arm (fewer extracted nodes ⇒ fewer downstream
                         dedupe/resolution LLM calls ⇒ lower token cost). Direct token capture requires
                         instrumenting the write-path LLM client — Wave 3 write-side observability scope.

  python3 graphiti-wave2-measure.py                                  # print the three deltas
  python3 graphiti-wave2-measure.py --emit-findings <path>           # also write the findings doc

The Decision rule is transparent and documented in the emitted findings (see decide()).
The operator-authored freeform module (~/graphiti/graphiti_ontology.py) is UNTOUCHED
regardless of the Decision — SHIP-to-default is a follow-up wave, not this script's action (AC-023).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE = HERE / "tests" / "fixtures" / "graphiti-eval-set.jsonl"
READ_SCRIPT = HERE / "graphiti-read.py"  # the comparability anchor — invoked, never reimplemented
GRAPHITI_REPO = (os.environ.get("GRAPHITI_REPO") or next((d for d in (os.path.expanduser("~/graphiti"), os.path.expanduser("~/Desktop/Dev/graphiti"), os.path.expanduser("~/Desktop/Development/graphiti")) if os.path.isdir(d)), os.path.expanduser("~/graphiti")))
TELEMETRY_DIR = Path(GRAPHITI_REPO) / "mcp_server" / "custom" / "telemetry"
MCP = os.environ.get("GRAPHITI_MCP_CONTAINER", "docker-graphiti-mcp-1")
PYV = "/app/mcp/.venv/bin/python"

NOISE = 0.05  # n=12, per-case recall granularity is coarse; |delta| <= NOISE is within-noise.


def topic_slug(context: str) -> str:
    """Identical slug to graphiti-wave2-ab.py (kept in sync deliberately — both derive from context)."""
    s = context.lower()[:24]
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    s = re.sub(r"-+", "-", s)
    return s or "case"


def load_cases() -> list[dict]:
    cases = []
    for line in FIXTURE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if "_comment" in obj:
            continue
        cases.append(obj)
    return cases


def run_read(group_id: str, top_k: int) -> str:
    """Invoke the UNMODIFIED graphiti-read.py recency Cypher (AC-022 read-path identity anchor)."""
    out = subprocess.run(  # subprocess-invoke graphiti-read.py — NEVER an inline Cypher (AC-022)
        [sys.executable, str(READ_SCRIPT), "--group-id", group_id, "--top-k", str(top_k),
         "--max-bytes", "100000"],
        capture_output=True, text=True, timeout=30,
    )
    return out.stdout.lower()


def recall_for_arm(cases: list[dict], arm: str) -> dict:
    """Per-case + overall recall@k for one A/B arm."""
    per_case, total_hits, total_expected = [], 0, 0
    for case in cases:
        topic = topic_slug(case["context"])
        gid = f"ab-wave2-{arm}-{topic}"
        text = run_read(gid, int(case.get("top_k", 30)))
        expected = case.get("expected_facts", [])
        hits = [e for e in expected if e.lower() in text]
        recall = (len(hits) / len(expected)) if expected else 1.0
        per_case.append({"topic": topic, "recall": round(recall, 3),
                         "hits": len(hits), "expected": len(expected)})
        total_hits += len(hits)
        total_expected += len(expected)
    overall = (total_hits / total_expected) if total_expected else 0.0
    return {"overall": round(overall, 4), "per_case": per_case,
            "hits": total_hits, "expected": total_expected}


def neo4j_metrics(topics: list[str]) -> dict:
    """One docker-exec read: per-arm entity/fact yield + zero-entity-episode counts for the eval topics.

    READ-only (MATCH ... RETURN); inspection, not a write. Returns {} if docker/container is absent."""
    if not (subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True,
                           text=True).stdout.find(MCP) >= 0):
        return {}
    snippet = r'''
import os, json
from neo4j import GraphDatabase
topics = json.loads(os.environ["W2_TOPICS"])
d = GraphDatabase.driver(os.environ["NEO4J_URI"], auth=(os.environ["NEO4J_USER"], os.environ["NEO4J_PASSWORD"]))
out = {}
with d.session() as s:
    for arm in ("typed", "freeform"):
        gids = [f"ab-wave2-{arm}-{t}" for t in topics]
        ent = s.run("MATCH (n:Entity) WHERE n.group_id IN $g RETURN count(n) AS c", g=gids).single()["c"]
        fac = s.run("MATCH ()-[r:RELATES_TO]->() WHERE r.group_id IN $g RETURN count(r) AS c", g=gids).single()["c"]
        # episodes with zero extracted entities = topics whose group has an Episodic but no Entity
        zero = 0
        for gid in gids:
            has_ep = s.run("MATCH (n:Episodic) WHERE n.group_id=$g RETURN count(n) AS c", g=gid).single()["c"]
            has_ent = s.run("MATCH (n:Entity) WHERE n.group_id=$g RETURN count(n) AS c", g=gid).single()["c"]
            if has_ep > 0 and has_ent == 0:
                zero += 1
        labels = s.run("MATCH (n:Entity) WHERE n.group_id IN $g UNWIND labels(n) AS l RETURN DISTINCT l", g=gids).data()
        out[arm] = {"entities": ent, "facts": fac, "zero_entity_episodes": zero,
                    "labels": sorted({r["l"] for r in labels})}
print(json.dumps(out))
d.close()
'''
    proc = subprocess.run(
        ["docker", "exec", "-e", f"W2_TOPICS={json.dumps(topics)}", "-w", "/app/mcp", MCP, PYV, "-c", snippet],
        capture_output=True, text=True, timeout=60,
    )
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return {}


def telemetry_ab_records(topics: list[str]) -> int:
    """Count telemetry records bearing an ab-wave2 group_id (expected 0 — see module docstring)."""
    if not TELEMETRY_DIR.exists():
        return 0
    n = 0
    for f in sorted(TELEMETRY_DIR.glob("telemetry-*.jsonl")):
        for line in f.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            gid = rec.get("group_id") or ""
            if gid.startswith("ab-wave2-"):
                n += 1
    return n


def decide(recall_typed: float, recall_freeform: float, telemetry_records: int) -> tuple[str, str]:
    """Transparent, documented decision rule. Returns (decision, rationale)."""
    delta = recall_typed - recall_freeform
    if delta > NOISE:
        return ("SHIP-TO-DEFAULT",
                f"typed recall {recall_typed:.3f} exceeds freeform {recall_freeform:.3f} by "
                f"{delta:+.3f} (> noise {NOISE}); typed retrieves strictly better.")
    if -delta > NOISE:
        return ("KEEP FREEFORM DEFAULT",
                f"typed recall {recall_typed:.3f} trails freeform {recall_freeform:.3f} by "
                f"{delta:+.3f} (> noise {NOISE}); typed degrades retrieval — keep the operator default.")
    # Within recall noise. We do NOT flip the operator's freeform default on a cost proxy alone,
    # especially with direct token numbers unavailable (telemetry infeasible for this write path).
    return ("INDETERMINATE",
            f"recall delta {delta:+.3f} is within case-level noise (±{NOISE}, n=12), and direct "
            f"token measurement was infeasible (telemetry ab-wave2 records: {telemetry_records}). A "
            f"within-noise recall does not justify flipping the operator's freeform default; Wave 4 inherits.")


def render_findings(cases, rt, rf, neo, tele, decision, rationale, criterion) -> str:
    delta = rt["overall"] - rf["overall"]
    typed_n = neo.get("typed", {})
    free_n = neo.get("freeform", {})
    n = len(cases)

    def yield_line(arm_n):
        if not arm_n:
            return "n/a (neo4j unavailable)"
        ent, fac = arm_n.get("entities", 0), arm_n.get("facts", 0)
        return (f"{ent} entities, {fac} facts over {n} episodes "
                f"(mean {ent / n:.1f} entities / {fac / n:.1f} facts per episode)")

    rows = []
    for ct, cf in zip(rt["per_case"], rf["per_case"]):
        d = ct["recall"] - cf["recall"]
        rows.append(f"| `{ct['topic']}` | {ct['recall']:.2f} ({ct['hits']}/{ct['expected']}) "
                    f"| {cf['recall']:.2f} ({cf['hits']}/{cf['expected']}) | {d:+.2f} |")
    table = "\n".join(rows)

    typed_labels = ", ".join(typed_n.get("labels", [])) or "—"
    free_labels = ", ".join(free_n.get("labels", [])) or "—"

    return f"""# Wave 2 — Typed vs Freeform A/B Findings

_graphiti-cost-efficiency epic · Wave 2 (wave-2-typed-entities) · generated by `core/scripts/graphiti-wave2-measure.py`._

## Methodology

- **Eval set:** the {n} hand-judged cases in `core/scripts/tests/fixtures/graphiti-eval-set.jsonl`
  (Wave 1's immutable fixture: `context` question + `expected_facts` substrings + `top_k`).
- **A/B partitions:** each case's body was written TWICE by `graphiti-wave2-ab.py` via the sanctioned
  `graphiti_write.write_fact()` path — `ab-wave2-typed-<topic>` (entity_types=ENTITY_TYPES, the 11 typed
  classes) and `ab-wave2-freeform-<topic>` (entity_types=None). Body synthesized from `context` +
  `expected_facts`; **byte-identical across arms**, so the A/B isolates the ontology variable.
  (Delimiter is `-` not `:`: graphiti-core 0.28.1 rejects colons in group_id — W2TE-T3 finding.)
- **Read path:** recall@k uses the UNMODIFIED `core/scripts/graphiti-read.py` recency Cypher (Wave 0 §5.4
  comparability anchor), invoked by subprocess — never an inline Cypher (AC-022). The freeform arm is the
  apples-to-apples re-baseline, NOT a regression check against the pre-A/B 0.424 number.
- **"Entity not found" criterion (Open Question 4 — implementer's choice):** measured DIRECTLY from neo4j
  as the count of episodes that produced zero extracted `Entity` nodes per arm. This direct signal replaces
  the spec's telemetry-token-threshold heuristic, which is **infeasible** here (see Token-per-episode).
- **Episode-window / token note:** the spec's token-per-episode telemetry join (ADR-074 sink) is
  **infeasible for this write path** — `graphiti_write.py`'s `_INNER` builds its own `AnthropicClient` and
  does NOT route through the Gemini client that ADR-074's telemetry wraps; the sink carries **{tele}**
  ab-wave2 records. The available cost signal is the neo4j extraction-yield proxy below.

## Recall@k delta

Overall recall@k — **typed {rt['overall']:.4f}** ({rt['hits']}/{rt['expected']}) vs
**freeform {rf['overall']:.4f}** ({rf['hits']}/{rf['expected']}) — **delta {delta:+.4f}** (typed − freeform).

| topic | typed recall | freeform recall | Δ |
|---|---|---|---|
{table}

Entity labels extracted — typed: {{{typed_labels}}}; freeform: {{{free_labels}}}. The typed ontology
steers extraction into typed classes; freeform produces only the generic `Entity` label.

## Entity-not-found rate

Episodes yielding ZERO extracted entities (of {n}) — typed: **{typed_n.get('zero_entity_episodes', 'n/a')}**;
freeform: **{free_n.get('zero_entity_episodes', 'n/a')}**. (Criterion: direct neo4j zero-entity-episode
count, per Methodology — the telemetry-based criterion is infeasible for this write path.)

## Token-per-episode delta

Direct per-call token measurement is **infeasible** for the deliberate-write A/B path: the telemetry sink
(ADR-074) wraps the Gemini routing client, but `graphiti_write.py` extracts via a separate, uninstrumented
`AnthropicClient`. Telemetry ab-wave2 records found: **{tele}**.

Available cost PROXY — extraction yield per episode (fewer extracted nodes ⇒ fewer downstream
dedupe/edge-resolution LLM calls ⇒ lower token cost):
- **typed:** {yield_line(typed_n)}
- **freeform:** {yield_line(free_n)}

Closing this to a direct token number requires instrumenting the write-path LLM client (the
`AnthropicClient` in `graphiti_write.py`'s `_INNER`) — **Wave 3 write-side observability scope**
(ties to `docs/step-1-ideas/DEFER-2026-06-09-graphiti-write-deadletter-live-evidence.md`).

## Decision rationale

{rationale}

The operator-authored freeform-by-default decision module (`~/graphiti/graphiti_ontology.py`)
is UNTOUCHED by this wave regardless of the Decision below — typed remains an opt-in per-`group_id`
capability; flipping the default is a separate, operator-ratified follow-up (AC-023).

Decision: {decision}
"""


def main() -> int:
    ap = argparse.ArgumentParser(description="Typed-vs-freeform A/B measurement (Wave 2).")
    ap.add_argument("--emit-findings", metavar="PATH", default=None,
                    help="write the findings document (with the binding Decision line) to PATH")
    args = ap.parse_args()

    cases = load_cases()
    topics = [topic_slug(c["context"]) for c in cases]

    rt = recall_for_arm(cases, "typed")
    rf = recall_for_arm(cases, "freeform")
    neo = neo4j_metrics(topics)
    tele = telemetry_ab_records(topics)
    decision, rationale = decide(rt["overall"], rf["overall"], tele)
    criterion = "zero-entity-episode count (direct neo4j)"

    print(f"Recall@k  — typed {rt['overall']:.4f} | freeform {rf['overall']:.4f} | "
          f"delta {rt['overall'] - rf['overall']:+.4f}")
    if neo:
        print(f"Yield     — typed {neo['typed']['entities']}ent/{neo['typed']['facts']}facts | "
              f"freeform {neo['freeform']['entities']}ent/{neo['freeform']['facts']}facts")
        print(f"Zero-ent  — typed {neo['typed']['zero_entity_episodes']} | "
              f"freeform {neo['freeform']['zero_entity_episodes']} (of {len(cases)})")
    print(f"Telemetry — ab-wave2 records: {tele} (0 expected; telemetry infeasible for this path)")
    print(f"Decision  — {decision}")

    if args.emit_findings:
        out = render_findings(cases, rt, rf, neo, tele, decision, rationale, criterion)
        path = Path(args.emit_findings)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(out, encoding="utf-8")
        print(f"findings -> {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
