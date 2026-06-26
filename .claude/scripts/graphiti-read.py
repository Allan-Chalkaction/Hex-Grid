#!/usr/bin/env python3
"""graphiti-read — pull salient durable facts for a group_id from the Graphiti graph.

Wave 3 read path, v2. The engine is fully Dockerized (no host graphiti_core / neo4j driver),
so this reads over Neo4j's HTTP Query API (`POST http://localhost:7474/db/neo4j/query/v2`) using
stdlib `urllib.request` only — dependency-free on the host (no `requests`, no neo4j driver). This
replaced the old `docker exec <neo4j> cypher-shell` transport, which paid cypher-shell's JVM
cold-start (~1.2s) on every call; the HTTP Query API runs the same Cypher with no JVM spin-up
(~0.10s, 12x measured 2026-06-08). The Cypher, recency semantics, byte-cap, and framing are
unchanged. It returns the most recent `RELATES_TO.fact` distillates for a group, framed
"recalled — may be stale, verify against source" per the trust-framing rule.

Auth is still resolved via `docker exec <neo4j> printenv NEO4J_AUTH` (the auth-resolution path,
not the fetch path) and sent as an HTTP Basic `Authorization` header — local-only, never logged.

This is the SessionStart "salient facts for this project" mode: no query, recency-ranked,
per-group scoped. A future semantic (`--query`-driven) mode would embed the query and search —
that needs the graphiti container's runtime and is deferred (roadmap Wave 3 ADR).

  python3 graphiti-read.py --group-id tmp-self-service --top-k 5 --max-bytes 1200

Always exits 0 (fail-open): on any error it emits nothing and logs to stderr, so a SessionStart
hook can never block or break the session. Designed to run under a hard `timeout` wrapper.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

FRAME_PREFIX = "Recalled (may be stale — verify against source: {src}): "

# Neo4j 5.x HTTP Query API endpoint path. Single named constant — never interpolated inline.
# The legacy transactional endpoint (/db/data/transaction/commit) returns 404 on this deployment;
# the v2 Query API is the live path (verified HTTP 202 against docker-neo4j-1, 2026-06-13).
NEO4J_QUERY_PATH = "/db/neo4j/query/v2"

CYPHER = (
    "MATCH (a:Entity)-[r:RELATES_TO]->(b:Entity) WHERE r.group_id = $g "
    "RETURN r.fact AS fact, r.created_at AS created ORDER BY r.created_at DESC LIMIT {k}"
)

# ADR-078: optional artifact-source TYPE filter. Restricts to facts whose mentioning episodes
# carry the [type:<tag>] marker in source_description (joined via RELATES_TO.episodes -> Episodic.uuid).
# Default reads are UNFILTERED (whole project group) — this is opt-in only.
CYPHER_TYPED = (
    "MATCH (a:Entity)-[r:RELATES_TO]->(b:Entity) WHERE r.group_id = $g "
    "AND EXISTS {{ MATCH (ep:Episodic) WHERE ep.uuid IN r.episodes "
    "AND ep.source_description CONTAINS $tmarker }} "
    "RETURN r.fact AS fact, r.created_at AS created ORDER BY r.created_at DESC LIMIT {k}"
)

# ADR-096 / W1: optional feature-domain filter. Restricts to facts whose mentioning episodes carry
# a [feature:<slug>] marker in source_description (same RELATES_TO.episodes -> Episodic.uuid join as
# CYPHER_TYPED). Multi-value is OR semantics: one anchored CONTAINS '[feature:<slug>]' clause per slug,
# OR-ed together, with one bound `fmarker0/fmarker1/...` param per slug. The complete bracketed-tag
# anchoring (paired with graphiti_write.py's repeated single-slug stamp form) prevents a substring
# false-match — --feature sdr will NOT surface [feature:sdr-experimental]. DEFAULT-OFF: a read with no
# --feature uses the unfiltered CYPHER above, so the SessionStart recency path is unchanged.
CYPHER_FEATURED = (
    "MATCH (a:Entity)-[r:RELATES_TO]->(b:Entity) WHERE r.group_id = $g "
    "AND EXISTS {{ MATCH (ep:Episodic) WHERE ep.uuid IN r.episodes "
    "AND ({clauses}) }} "
    "RETURN r.fact AS fact, r.created_at AS created ORDER BY r.created_at DESC LIMIT {k}"
)


def _neo4j_password(container: str) -> str | None:
    env = os.environ.get("GRAPHITI_NEO4J_PASSWORD")
    if env:
        return env
    try:
        auth = subprocess.run(
            ["docker", "exec", container, "printenv", "NEO4J_AUTH"],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return None
    # NEO4J_AUTH is "neo4j/<password>"
    return auth.split("/", 1)[1] if "/" in auth else None


# Mirrors the write rail's ^[A-Za-z0-9_-]+$ gate (~/graphiti/graphiti_features._CHARSET). A slug that
# fails this is DROPPED here so it can never reach the cypher-shell parameter expression at fetch_facts
# (SA-001 / ADR-096: write-read validation symmetry — a quote/bracket-bearing slug is dropped, not
# interpolated into `fmarker{i} => '[feature:{slug}]'`).
_FEATURE_CHARSET = re.compile(r"^[a-z0-9_-]+$")


def _feature_slugs(feature: str | None) -> list[str]:
    """Parse the comma-delimited --feature value into normalized, charset-validated slugs (case-insensitive).

    Each slug is lowercased/trimmed then charset-gated (^[a-z0-9_-]+$); slugs that fail the gate are
    dropped before they can reach the query parameter expression (SA-001 write/read symmetry)."""
    if not feature:
        return []
    return [s for s in (x.strip().lower() for x in feature.split(",")) if s and _FEATURE_CHARSET.match(s)]


def fetch_facts(group_id: str, top_k: int, container: str, user: str, timeout_s: float,
                source_type: str | None = None, feature: str | None = None,
                http_endpoint: str = "localhost:7474") -> list[str]:
    password = _neo4j_password(container)
    if not password:
        print("graphiti-read: no neo4j password (set GRAPHITI_NEO4J_PASSWORD or run engine)", file=sys.stderr)
        return []
    # Build the query + params. The $g / $fmarker / $tmarker placeholders already match the HTTP API's
    # param names — CYPHER / CYPHER_FEATURED / CYPHER_TYPED are passed verbatim, never string-interpolated
    # with group_id / slug / source_type (injection-safe; preserves the typed + feature paths).
    parameters: dict[str, str] = {"g": group_id}
    slugs = _feature_slugs(feature)
    if slugs:
        # ADR-096 / W1: OR over one anchored CONTAINS '[feature:<slug>]' clause per slug, each bound
        # to its own fmarker param (no string interpolation of the slug into the query body). The
        # complete [feature:<slug>] bracketing is what blocks the sdr -> sdr-experimental false-match.
        clauses = " OR ".join(f"ep.source_description CONTAINS $fmarker{i}" for i in range(len(slugs)))
        query = CYPHER_FEATURED.format(clauses=clauses, k=int(top_k))
        for i, slug in enumerate(slugs):
            parameters[f"fmarker{i}"] = f"[feature:{slug}]"
    elif source_type:
        # marker is the literal [type:<tag>] substring stamped by graphiti_write.py (ADR-078)
        query = CYPHER_TYPED.format(k=int(top_k))
        parameters["tmarker"] = f"[type:{source_type}]"
    else:
        query = CYPHER.format(k=int(top_k))

    # Transport: Neo4j HTTP Query API (replaces docker-exec cypher-shell — no JVM cold-start).
    url = f"http://{http_endpoint}{NEO4J_QUERY_PATH}"
    body = json.dumps({"statement": query, "parameters": parameters}).encode("utf-8")
    token = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
    req = urllib.request.Request(
        url, data=body, method="POST",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json",
            "Authorization": f"Basic {token}",  # HTTP Basic; password never logged
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout_s) as resp:
            status = resp.getcode()
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        # Non-2xx (401 bad auth, 5xx, etc.). Truncate the body before logging — never echo creds.
        try:
            detail = e.read().decode("utf-8", "replace").strip()[:200]
        except OSError:
            detail = ""
        print(f"graphiti-read: http error {e.code}: {detail}", file=sys.stderr)
        return []
    except (urllib.error.URLError, OSError) as e:
        # Connection refused (Neo4j down), DNS, socket timeout — all fail-open.
        print(f"graphiti-read: http transport failed (neo4j unreachable?): {e}", file=sys.stderr)
        return []
    # The Query API returns 202 on success (not 200) — accept any 2xx.
    if not (200 <= status < 300):
        print(f"graphiti-read: http non-2xx status {status}", file=sys.stderr)
        return []
    try:
        payload = json.loads(raw)
    except (ValueError, TypeError) as e:
        print(f"graphiti-read: malformed json body: {e}", file=sys.stderr)
        return []
    # v2 shape: {"data": {"fields": [...], "values": [[...], ...]}}. Empty/sparse graph -> [] (the
    # expected cold-start steer, NOT an error). 'fact' is the first selected column (row[0]).
    values = (payload.get("data") or {}).get("values") or []
    facts = []
    for row in values:
        if row and isinstance(row[0], str) and row[0].strip():
            facts.append(row[0].strip())
    return facts


def render(facts: list[str], group_id: str, max_bytes: int) -> str:
    """Frame facts as distillate+pointer, accumulating until the byte budget is hit."""
    lines, used = [], 0
    for fact in facts:
        line = FRAME_PREFIX.format(src=group_id) + fact
        if used + len(line.encode("utf-8")) > max_bytes:
            break
        lines.append("- " + line)
        used += len(line.encode("utf-8"))
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description="Read salient durable facts for a group_id.")
    ap.add_argument("--group-id", required=True)
    ap.add_argument("--source-type", default=None,
                    help="optional artifact-type filter (e.g. adr); default reads the whole group (ADR-078)")
    ap.add_argument("--feature", default=None,
                    help="optional feature-domain filter (comma-delimited, OR semantics; e.g. sdr,self-service); "
                         "DEFAULT-OFF — omit to read the whole group (ADR-096)")
    ap.add_argument("--top-k", type=int, default=5)
    ap.add_argument("--max-bytes", type=int, default=1200, help="hard cap on injected text size")
    ap.add_argument("--neo4j-container", default=os.environ.get("GRAPHITI_NEO4J_CONTAINER", "docker-neo4j-1"))
    ap.add_argument("--neo4j-user", default=os.environ.get("GRAPHITI_NEO4J_USER", "neo4j"))
    ap.add_argument("--neo4j-http", default=os.environ.get("GRAPHITI_NEO4J_HTTP", "localhost:7474"),
                    help="host:port for the Neo4j HTTP Query API (default localhost:7474)")
    ap.add_argument("--timeout", type=float, default=5.0, help="seconds for the HTTP query call")
    ap.add_argument("--meter", action="store_true", help="print a meter line to stderr")
    args = ap.parse_args()

    t0 = time.monotonic()
    facts = fetch_facts(args.group_id, args.top_k, args.neo4j_container, args.neo4j_user, args.timeout,
                        source_type=args.source_type, feature=args.feature,
                        http_endpoint=args.neo4j_http)
    text = render(facts, args.group_id, args.max_bytes)
    elapsed_ms = int((time.monotonic() - t0) * 1000)

    if text:
        sys.stdout.write(text + "\n")
    if args.meter:
        print(
            f"Graphiti-read: injected={len(text.encode('utf-8'))} bytes, "
            f"facts={text.count(chr(10)) + 1 if text else 0}, latency={elapsed_ms}ms, group_id={args.group_id}",
            file=sys.stderr,
        )
    return 0  # always fail-open


if __name__ == "__main__":
    sys.exit(main())
