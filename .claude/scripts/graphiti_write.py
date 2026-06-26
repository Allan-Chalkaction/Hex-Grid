#!/usr/bin/env python3
"""graphiti-write — the single safe write path into the Graphiti graph.

Every write (deliberate `remember` and automated capture) goes through write_fact(), which:
  1. SCRUBS secrets (mandatory — graphiti-scrubber.py),
  2. resolves a FAIL-CLOSED group_id (derive from cwd or validate a supplied one; never main/guess),
  3. mints a DETERMINISTIC uuid (uuid5 of group_id+content) so a re-fire is a no-op, not a dup,
  4. carries PROVENANCE (source_description) — distillate + pointer, never a bare pointer,
  5. writes freeform via graphiti_core.add_episode INSIDE the mcp container (no host runtime).

CLI form is the deliberate "remember this" rail:
  python3 graphiti-write.py "Upside's MID discovery relies on Worldpay and Fiserv"
  python3 graphiti-write.py --group-id nia --source "manual note" "..."
  python3 graphiti-write.py --dry-run "..."         # scrub + resolve + uuid, but DON'T write

Importable: write_fact(text, group_id=None, source_description=..., name=None, dry_run=False, cwd=None).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import uuid as _uuid
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from graphiti_scrubber import scrub  # noqa: E402

GRAPHITI_REPO = (os.environ.get("GRAPHITI_REPO") or next((d for d in (os.path.expanduser("~/graphiti"), os.path.expanduser("~/Desktop/Dev/graphiti"), os.path.expanduser("~/Desktop/Development/graphiti")) if os.path.isdir(d)), os.path.expanduser("~/graphiti")))
MCP_CONTAINER = os.environ.get("GRAPHITI_MCP_CONTAINER", "docker-graphiti-mcp-1")

# Runs inside the mcp container (has graphiti_core + NEO4J_*/API-key env). Reads one JSON payload
# from stdin. Builds the same clients the MCP server uses (Anthropic haiku LLM + OpenAI embedder)
# so extraction works — a bare Graphiti() has no LLM client and fails on add_episode.
_INNER = r"""
import sys, json, asyncio, os
from datetime import datetime, timezone
from graphiti_core import Graphiti
from graphiti_core.nodes import EpisodeType
from graphiti_core.llm_client.anthropic_client import AnthropicClient
from graphiti_core.llm_client.config import LLMConfig
from graphiti_core.embedder.openai import OpenAIEmbedder, OpenAIEmbedderConfig

p = json.load(sys.stdin)

# W3IO-T2: write-path telemetry wrap (ADR-074 lane:"write"). The write rail builds its OWN
# AnthropicClient (see _client below), NOT the Gemini routing client the server-side ADR-074
# telemetry wraps — so write-path token cost was invisible (Wave 2 close finding). Patch
# AnthropicClient._generate_response (returns tuple[dict, in_tok, out_tok]) to emit the closed tuple
# per LLM call. Idempotent (class sentinel: no double-wrap on re-import) and FAIL-OPEN (a telemetry
# error logs ONE stderr line and is swallowed — never raised into the add_episode path).
import time, contextvars
_WRITE_CTX = contextvars.ContextVar("graphiti_write_ctx", default=None)

def _emit_write_telemetry(in_tok, out_tok, t0):
    ctx = _WRITE_CTX.get() or {}
    rec = {
        "schema_version": "1",
        "ts": datetime.now(timezone.utc).isoformat(),
        "operation": (ctx.get("name") or "write_episode")[:80],
        "model": os.environ.get("MODEL_NAME", "claude-haiku-4-5"),
        "lane": "write",
        "input_tokens": in_tok,
        "output_tokens": out_tok,
        "duration_ms": int((time.monotonic() - t0) * 1000),
        "episode_id": None,
        "group_id": ctx.get("group_id"),
        "content_hash": ctx.get("content_hash"),   # host-passed via payload (CR-003) — joins to manifest/dead-letter
    }
    d = "/app/mcp/telemetry"
    os.makedirs(d, exist_ok=True)
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    with open(os.path.join(d, f"telemetry-{day}.jsonl"), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec) + "\n")

if not getattr(AnthropicClient, "_write_telemetry_patched", False):
    _real_generate = AnthropicClient._generate_response
    async def _wrapped_generate(self, *args, **kwargs):
        t0 = time.monotonic()
        resp = await _real_generate(self, *args, **kwargs)   # tuple (dict, input_tokens, output_tokens)
        try:
            _emit_write_telemetry(resp[1], resp[2], t0)
        except Exception as _e:
            print(f"telemetry-emit-failed: {_e}", file=sys.stderr)
        return resp
    AnthropicClient._generate_response = _wrapped_generate
    AnthropicClient._write_telemetry_patched = True

def _client():
    llm = AnthropicClient(config=LLMConfig(
        api_key=os.environ["ANTHROPIC_API_KEY"],
        model=os.environ.get("MODEL_NAME", "claude-haiku-4-5")))
    emb = OpenAIEmbedder(config=OpenAIEmbedderConfig(
        api_key=os.environ["OPENAI_API_KEY"],
        # 1024 to match the stored 1024-dim name_embeddings (see config-docker-neo4j.yaml). A 1536-dim
        # query vector breaks add_episode dedup with a vector.similarity.cosine() dimension mismatch.
        embedding_model="text-embedding-3-small", embedding_dim=1024))
    return Graphiti(os.environ["NEO4J_URI"], os.environ["NEO4J_USER"], os.environ["NEO4J_PASSWORD"],
                    llm_client=llm, embedder=emb)

async def run():
    g = _client()
    try:
        # No explicit uuid: add_episode(uuid=...) means "update an EXISTING node" and raises
        # NodeNotFoundError for a new one. graphiti mints the uuid; idempotency is handled on the
        # host via a content-hash pre-check (the [sha:...] marker in source_description).
        # Wave 2 typed-entity A/B: ENTITY_TYPES is defined by the ontology source prepended to this
        # body host-side (_compose_inner). "typed" selector -> typed bundle; else freeform (None).
        sel = p.get("ontology_select", "freeform")
        entity_types = ENTITY_TYPES if sel == "typed" else None
        # W3IO-T1: deterministic-UUID create-vs-update branch. update_uuid present (the host resolved
        # a manifest hit for this content_hash+group_id) -> UPDATE the existing episode node by uuid;
        # absent -> CREATE (graphiti mints — passing uuid= for a NEW node raises NodeNotFoundError,
        # Wave 0 V4 RED). Print the resolved uuid so the host (T3) can record it on the CREATE arm.
        # W3IO-T2: task-local attribution for the write-path telemetry wrap (ContextVar — correct
        # under future concurrency; the wrapper reads group_id/name from here).
        _WRITE_CTX.set({"group_id": p["group_id"], "name": p.get("name", ""),
                        "content_hash": p.get("content_hash")})
        update_uuid = p.get("update_uuid")
        add_kwargs = dict(
            name=p["name"], episode_body=p["body"], source_description=p["source_description"],
            reference_time=datetime.now(timezone.utc), source=EpisodeType.text,
            group_id=p["group_id"],
            entity_types=entity_types,    # W2TE-T2 (architect D1) — per-call kwarg seam
            edge_types=None,              # architect D4 — edge typing OMITTED, unconditionally
            edge_type_map={},             # architect D4 — unconditionally empty
        )
        if update_uuid:
            add_kwargs["uuid"] = update_uuid
        res = await g.add_episode(**add_kwargs)
        episode_uuid = update_uuid or getattr(getattr(res, "episode", None), "uuid", "") or ""
        print(f"OK {episode_uuid}")
    except Exception as e:
        print("ERR " + repr(e)); sys.exit(1)
    finally:
        close = getattr(g, "close", None)
        if close:
            r = close()
            if asyncio.iscoroutine(r):
                await r

asyncio.run(run())
"""

# Wave 2 (graphiti-cost-efficiency) typed-entity A/B wire-in (architect D2 Option b):
# the typed Pydantic classes + the ENTITY_TYPES map live in a sibling file that is delivered to the
# container by inlining its SOURCE TEXT into _INNER before docker exec (no new bind-mount, no
# container recreate). Read once at module load so an I/O / syntax error surfaces at import time.
_ONTOLOGY_INNER_SRC = (Path(__file__).resolve().parent / "graphiti_ontology_inner.py").read_text(encoding="utf-8")


def _select_ontology(group_id: str) -> str:
    """Single source of truth for typed-vs-freeform routing (host-side).

    Returns "typed" only for the Wave 2 A/B typed arm (group_id prefix ``ab-wave2-typed-``);
    "freeform" otherwise. The operator-authored freeform-by-default decision (2026-06-08) is
    preserved for EVERY non-A/B group_id, including the live capture group ``claude-infra-v2``.

    Delimiter note: the A/B namespace uses ``-`` (not ``:``) because graphiti-core 0.28.1's
    helpers.validate_group_id rejects any group_id containing a colon (charset is ASCII
    alphanumeric + dash + underscore only). The colon convention in ADR-073 R5 / architect D5 is
    therefore infeasible at the engine layer; the dash form preserves identical A/B semantics.
    """
    if group_id.startswith("ab-wave2-typed-"):
        return "typed"
    return "freeform"


def _compose_inner(inner_body: str) -> str:
    """Prepend the in-container ontology source to the _INNER body, syntax-checking host-side.

    The composed unit is what ``docker exec ... python -c`` receives. We ``compile()`` it on the
    HOST first so a syntax error in graphiti_ontology_inner.py (or the composition) raises a loud
    host-side RuntimeError at write time, rather than failing silently inside the container.
    compile() parses only — it does not import pydantic or execute the classes.
    """
    combined = _ONTOLOGY_INNER_SRC + "\n" + inner_body
    try:
        compile(combined, "<wave2-typed-inner>", "exec")
    except SyntaxError as e:
        raise RuntimeError(
            f"graphiti_ontology_inner.py composed with _INNER fails host-side syntax check: {e}"
        ) from e
    return combined


def _resolve_group_id(group_id, cwd):
    sys.path.insert(0, GRAPHITI_REPO)
    import graphiti_groups as gg
    reg = gg.load_registry()
    if group_id:
        _, gid = gg.validate_group_id(group_id, reg)   # fail-closed -> quarantine on miss
        return gid
    return gg.derive_group_id(cwd or os.getcwd(), reg)  # fail-closed -> quarantine outside projects-active


def _resolve_source_type(source_type):
    """Resolve the artifact-source TYPE tag, failing OPEN (ADR-078).

    Returns the effective tag to stamp as `[type:<tag>]`. Unlike group_id (fail-closed),
    an unregistered-but-valid type is preserved as given with a stderr warning (so the drift
    is reconciled by a one-line registry add, never silently re-bucketed); a missing/invalid
    type falls back to the registry default. A benign registry-load failure also fails open
    (no tag) — a missing source registry must never block a write.
    """
    if not source_type:
        return None
    try:
        sys.path.insert(0, GRAPHITI_REPO)
        import graphiti_sources as gs
        known, eff = gs.validate_source(source_type, gs.load_sources())
    except Exception as e:  # fail-open: registry missing/unreadable -> tag as-given, warn
        print(f"source-registry-unavailable: {e} — tagging [type:{source_type}] unvalidated", file=sys.stderr)
        return source_type
    if not known and eff == source_type:
        print(f"UNREGISTERED_SOURCE: {eff} — add to graphiti_sources.json", file=sys.stderr)
    return eff


def _resolve_feature(slug):
    """Resolve a single feature-domain slug, failing OPEN (ADR-096 / W1).

    Returns the effective slug to stamp as `[feature:<slug>]`, or None for no tag.
    Mirrors `_resolve_source_type` (the [type:] sibling) with ONE deliberate divergence
    (AC-021): the deployed `validate_feature` returns (False, fallback) — i.e. "general" —
    on a missing/empty/invalid slug, but feature has NO fallback tag. An unresolvable
    feature is simply absent, never `[feature:general]` by accident. So:
      - known registered slug          -> effective tag
      - unregistered-but-charset-valid -> preserved as given + one UNREGISTERED_FEATURE stderr line
      - missing / empty / invalid       -> None (the (False, fallback) arm maps to no tag)
      - registry-load failure (except)  -> None (fail open: no tag, one stderr line)
    NEVER fails closed, NEVER blocks a write. (Contrast `_resolve_group_id`, which fails closed —
    a mis-tagged feature is low-stakes provenance-of-relevance, not a cross-tenant leak.)
    """
    if not slug:
        return None
    try:
        sys.path.insert(0, GRAPHITI_REPO)
        import graphiti_features as gf
        reg = gf.load_features()
        known, eff = gf.validate_feature(slug, reg)
    except Exception as e:  # fail-open: registry missing/unreadable -> no tag, warn
        print(f"feature-registry-unavailable: {e} — dropping [feature:{slug}] (no tag)", file=sys.stderr)
        return None
    # The (False, fallback) arm == missing/empty/invalid slug -> no tag (the AC-021 divergence).
    if not known and eff == reg.fallback:
        return None
    if not known and eff == _normalize_feature(slug):
        print(f"UNREGISTERED_FEATURE: {eff} — add to graphiti_features.json", file=sys.stderr)
    return eff


def _normalize_feature(slug):
    """Lowercase + trim a slug for comparison (mirrors graphiti_features._normalize)."""
    return (slug or "").strip().lower()


def _derive_features(source_path, frontmatter_feature, cli_features):
    """Hybrid feature-domain assignment (ADR-096 / W1). Returns an ordered list of resolved slugs.

    Order is binding (AC-005): path-segment FIRST, frontmatter SECOND, then the --feature
    override SETS-OR-AUGMENTS the derived set (case-insensitive, comma-delimited, de-duped).
    Assignment is deterministic — path / frontmatter / explicit-override only, no inference.

    Each candidate is run through _resolve_feature (fail-open); unresolvable candidates drop out.
    """
    candidates = []
    # 1. path-derived: a `docs/features/<feature>/` segment, FIRST.
    if source_path:
        parts = str(source_path).replace("\\", "/").split("/")
        for i, seg in enumerate(parts[:-1]):  # not the filename itself
            if seg == "features" and i > 0 and parts[i - 1] == "docs" and i + 1 < len(parts):
                candidates.append(parts[i + 1])
                break
    # 2. frontmatter `feature:` field, SECOND.
    if frontmatter_feature:
        candidates.append(frontmatter_feature)
    # 3. --feature override SETS-OR-AUGMENTS (comma-delimited, case-insensitive).
    if cli_features:
        for raw in cli_features.split(","):
            candidates.append(raw)
    # Resolve fail-open and de-dupe while preserving order.
    resolved, seen = [], set()
    for cand in candidates:
        eff = _resolve_feature(cand)
        if eff and eff not in seen:
            seen.add(eff)
            resolved.append(eff)
    return resolved


NEO4J_CONTAINER = os.environ.get("GRAPHITI_NEO4J_CONTAINER", "docker-neo4j-1")


def _neo4j_password():
    env = os.environ.get("GRAPHITI_NEO4J_PASSWORD")
    if env:
        return env
    try:
        auth = subprocess.run(["docker", "exec", NEO4J_CONTAINER, "printenv", "NEO4J_AUTH"],
                              capture_output=True, text=True, timeout=10).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return None
    return auth.split("/", 1)[1] if "/" in auth else None


def _already_written(gid, content_hash):
    """Idempotency: has an episode carrying this content-hash marker already landed in this group?"""
    pw = _neo4j_password()
    if not pw:
        return False  # can't check -> don't block the write
    q = ("MATCH (e:Episodic) WHERE e.group_id = $g AND e.source_description CONTAINS $h "
         "RETURN count(e) AS n")
    try:
        out = subprocess.run(
            ["docker", "exec", NEO4J_CONTAINER, "cypher-shell", "-u", "neo4j", "-p", pw,
             "--format", "plain", "-P", f"g => '{gid}'", "-P", f"h => 'sha:{content_hash}'", q],
            capture_output=True, text=True, timeout=15)
    except (subprocess.SubprocessError, OSError):
        return False
    tail = [l for l in out.stdout.splitlines() if l.strip().isdigit()]
    return bool(tail) and int(tail[-1]) > 0


def _content_hash(group_id, scrubbed):
    """Canonical content hash for a (group_id, scrubbed-body) pair.

    SINGLE SOURCE (AC-009/AC-016): the ONLY content-hash implementation across the
    graphiti_*.py modules. `graphiti_manifest.py` imports this — do NOT duplicate the
    computation anywhere else. Output is bit-for-bit identical to the prior inline form:
    sha256 of "group_id|scrubbed" (utf-8), first 16 hex chars. Do not alter the encoding,
    separator, or truncation length, and do not add normalization.
    """
    import hashlib
    return hashlib.sha256(f"{group_id}|{scrubbed}".encode("utf-8")).hexdigest()[:16]


def _is_needs_triage(gid):
    """True if a RESOLVED group_id is the fail-closed quarantine sink (W3IO-T6).

    The live quarantine string is read from the registry (graphiti_groups: ``reg.quarantine``,
    default ``unsorted:NEEDS_TRIAGE``) so this tracks any operator change to that constant — there is
    no separate NEEDS_TRIAGE_PREFIX module constant. ``startswith`` covers any future sub-bucketing.
    """
    try:
        sys.path.insert(0, GRAPHITI_REPO)
        import graphiti_groups as gg
        q = gg.load_registry().quarantine
    except Exception:
        q = "unsorted:NEEDS_TRIAGE"
    return bool(gid) and (gid == q or gid.startswith(q))


def _write_deadletter(record):
    """Append a failed-write record to the consumer-wrapper dead-letter sink (W3IO-T5).

    EXACTLY {ts, episode_name, group_id, content_hash, error} — NEVER a body/episode_body field
    (security invariant, AC-028/AC-032): content_hash is the reference; replaying requires
    re-sourcing the body from upstream, never reconstructing it from this sink. UTC daily JSONL
    (ADR-068 append discipline), lazy mkdir, FAIL-OPEN (a sink error logs one stderr line, swallowed).
    Sink: ${REPO_ROOT}/.claude/agent-memory/graphiti-deadletter/deadletter-YYYY-MM-DD.jsonl
    (.claude/agent-memory/ is gitignored — no .gitignore edit needed).
    """
    try:
        repo_root = os.environ.get("REPO_ROOT")
        if not repo_root:
            try:
                repo_root = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                                           capture_output=True, text=True, timeout=5).stdout.strip()
            except (subprocess.SubprocessError, OSError):
                repo_root = ""
        repo_root = repo_root or str(Path(__file__).resolve().parents[2])
        sink_dir = Path(repo_root) / ".claude" / "agent-memory" / "graphiti-deadletter"
        sink_dir.mkdir(parents=True, exist_ok=True)
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        with open(sink_dir / f"deadletter-{day}.jsonl", "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception as e:
        print(f"deadletter-write-failed: {e}", file=sys.stderr)


# AMS-T1 (wave-1-writes, AC-003/AC-006) — SOLE-WRITE-PATH confirmation (audit, not a rewrite).
# write_fact() is the single, non-bypassable funnel every W1 seam (persist post-persist seam, the
# SessionEnd live capture, and the commit-time ADR ingest via graphiti-ingest-doc.py) routes through.
# Verified invariants the downstream seams ride and MUST NOT re-implement:
#   - add_episode / a write-constructing Graphiti() exist ONLY inside _INNER (the in-container body);
#     no host-side or hook-side write surface constructs a graph client (AC-003 grep gate).
#   - scrub() (:316) runs on EVERY write before the body leaves this process (no secret reaches the graph).
#   - _resolve_group_id() (:190-197) is fail-CLOSED — a derivation/validation miss quarantines to
#     unsorted:NEEDS_TRIAGE, never a permissive shared group (the cross-project isolation fence).
#   - _content_hash() (:256-266) is the SINGLE content-hash source (graphiti_manifest imports it); a
#     re-fire of the same (group_id, scrubbed) is a no-op "duplicate", never a second episode (AC-006).
#   - force=True bypasses ONLY the Neo4j defense-in-depth fast path (:355), NOT the manifest gate.
# No new parameter is needed for the W1 seams — they consume the existing signature (group_id,
# source_path, heading_anchor, dry_run). Any future extension is additive and content-free (ADR-074).
def write_fact(text, group_id=None, source_description="deliberate remember", name=None,
               dry_run=False, cwd=None, force=False, source_path=None, heading_anchor=None,
               source_type=None, feature=None, frontmatter_feature=None):
    scrubbed, findings = scrub(text)
    gid = _resolve_group_id(group_id, cwd)
    stype = _resolve_source_type(source_type)
    # ADR-096 / W1: hybrid feature-domain assignment (path-segment first, frontmatter second,
    # --feature override sets-or-augments). Resolved AFTER scrub, fed into source_description ONLY
    # below (never into the episode body / scrubbed text). Each slug resolves fail-open.
    features = _derive_features(source_path, frontmatter_feature, feature)
    name = (name or scrubbed.strip().split("\n")[0])[:80] or "memory"
    content_hash = _content_hash(gid, scrubbed)
    # W3IO-T7: optional source-anchor provenance prefix (AC-030). [src:<repo-rel-path>[#<anchor>]] is
    # PREPENDED; the [sha:...] marker stays at the END. Omitting source_path preserves the prior format
    # byte-for-byte. heading_anchor without source_path is ignored (no anchor without a path). The
    # prefix surfaces values into source_description so the LLM can populate Wave 2's _SourceAnchored
    # fields for typed A/B groups; for freeform groups it is searchable provenance regardless.
    # ADR-078: artifact-source TYPE tag, prepended ahead of the [src:...] anchor:
    # [type:adr][src:path] <desc> [sha:...]. Outside the content hash, so idempotency is unaffected.
    type_prefix = f"[type:{stype}]" if stype else ""
    # ADR-096 / W1: the [feature:] axis, between [type:] and [src:] per the ADR order
    # [type:adr][feature:sdr][src:path]. REPEATED single-slug form ([feature:sdr][feature:self-service]),
    # NEVER comma-joined, so the read-side anchored CONTAINS '[feature:sdr]' matches a complete
    # bracketed tag (and can't substring-match [feature:sdr-experimental]). Empty when no feature
    # resolved, so the no-feature path is byte-for-byte unchanged.
    feature_prefix = "".join(f"[feature:{f}]" for f in features)
    src_prefix = ""
    if source_path:
        src_prefix = f"[src:{source_path}#{heading_anchor}] " if heading_anchor else f"[src:{source_path}] "
    # separator only when a bracket prefix is present with no [src:...] to space it off the description;
    # the no-prefix path stays byte-for-byte identical to the pre-ADR-078 format.
    sep = " " if ((type_prefix or feature_prefix) and not src_prefix) else ""
    # the hash marker rides in source_description so a re-fire can be detected (distillate + pointer)
    full_source = f"{type_prefix}{feature_prefix}{src_prefix}{sep}{source_description} [sha:{content_hash}]"
    payload = {"name": name, "body": scrubbed, "source_description": full_source, "group_id": gid,
               "ontology_select": _select_ontology(gid), "content_hash": content_hash}
    result = {"group_id": gid, "content_hash": content_hash, "name": name, "redacted": findings,
              "body": scrubbed, "source_description": full_source, "source_type": stype,
              "features": features, "dry_run": dry_run}

    # W3IO-T6: surface a fail-closed quarantine resolution (AC-029). Fires HERE — after resolution,
    # BEFORE the dry-run/duplicate/write decision — so a silent quarantine is always announced
    # regardless of write outcome. Security invariant: NO body / scrubbed text — group_id +
    # content_hash + the (already-scrubbed, ≤80-char) name are the references for follow-up triage.
    if _is_needs_triage(gid):
        print(f"NEEDS_TRIAGE: group_id={gid} content_hash={content_hash} name={name}", file=sys.stderr)

    if dry_run:
        result["status"] = "dry-run"
        return result

    # Defense-in-depth fast path (KEEP, W3IO-T1): the Neo4j-side content-hash marker short-circuits
    # the common re-fire before the manifest lookup. force=True bypasses THIS check only.
    if not force and _already_written(gid, content_hash):
        result["status"] = "duplicate"
        return result

    # W3IO-T1: the manifest is the PRIMARY idempotency gate. A hit -> UPDATE the existing episode
    # node (pass its uuid into _INNER); a miss -> CREATE (graphiti mints). force=True does NOT bypass
    # this — a forced re-ingest with a manifest hit still UPDATEs (re-process, not duplicate).
    # Lazy import: graphiti_manifest imports _content_hash from THIS module (circular at top-level).
    import graphiti_manifest  # noqa: E402
    existing = graphiti_manifest.lookup(content_hash, gid)
    is_create = existing is None
    if existing:
        payload["update_uuid"] = existing["episode_uuid"]

    try:
        proc = subprocess.run(
            ["docker", "exec", "-i", "-w", "/app/mcp", MCP_CONTAINER, "uv", "run", "python", "-c",
             _compose_inner(_INNER)],
            input=json.dumps(payload), capture_output=True, text=True,
        )
        ok = proc.returncode == 0 and "OK" in proc.stdout
        stdout = proc.stdout
        err_text = (proc.stdout + proc.stderr).strip()[-400:]
    except (subprocess.SubprocessError, OSError) as e:
        # W3IO-T5: a subprocess-level failure (docker missing, exec error) is also a dead-letter case.
        ok, stdout, err_text = False, "", str(e)[-400:]

    result["status"] = "written" if ok else "error"
    if not ok:
        result["error"] = err_text
        # W3IO-T5: persist the failed episode to the consumer-wrapper dead-letter sink (the SYNC CLI
        # surface — the async add_memory path is a separate, documented residual). EXACTLY five fields,
        # NO body (security invariant — content_hash is the reference).
        _write_deadletter({
            "ts": datetime.now(timezone.utc).isoformat(),
            "episode_name": name,
            "group_id": gid,
            "content_hash": content_hash,
            "error": err_text,
        })

    # W3IO-T3: on a successful CREATE, record the graphiti-minted uuid (parsed from T1's `OK <uuid>`
    # print) so the next write of this (content_hash, group_id) takes T1's UPDATE arm. UPDATE arm:
    # no new record (it already exists). Fail-open per ADR-068 — a manifest miss never fails the write.
    if ok and is_create:
        episode_uuid = ""
        for line in stdout.splitlines():
            s = line.strip()
            if s.startswith("OK"):
                parts = s.split()
                episode_uuid = parts[1] if len(parts) > 1 else ""
                break
        if episode_uuid:
            try:
                graphiti_manifest.record(content_hash, gid, episode_uuid,
                                         datetime.now(timezone.utc).isoformat())
            except Exception as e:
                print(f"manifest-record-failed: {e}", file=sys.stderr)
        else:
            print(f"manifest-record-skipped: no uuid parsed from _INNER stdout (gid={gid})", file=sys.stderr)
    return result


def main() -> int:
    ap = argparse.ArgumentParser(description="Deliberately remember a fact (the safe write rail).")
    ap.add_argument("text", nargs="?", help="the fact to remember (or pipe via stdin)")
    ap.add_argument("--group-id", default=None, help="explicit group_id (else derived from cwd, fail-closed)")
    ap.add_argument("--source", default="deliberate remember", help="provenance (source_description)")
    ap.add_argument("--source-type", default=None,
                    help="artifact type tag (registry-validated, fail-open): adr | session | ... (ADR-078)")
    ap.add_argument("--feature", default=None,
                    help="feature-domain tag(s) (registry-validated, fail-open; comma-delimited, "
                         "case-insensitive): sdr | self-service | ... — sets-or-augments path/frontmatter (ADR-096)")
    ap.add_argument("--name", default=None)
    ap.add_argument("--cwd", default=None, help="cwd to derive group_id from (default: this process's cwd)")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true", help="write even if a content-hash duplicate exists")
    args = ap.parse_args()

    text = args.text if args.text is not None else sys.stdin.read()
    if not text.strip():
        print("nothing to remember (empty text)", file=sys.stderr)
        return 2

    r = write_fact(text, group_id=args.group_id, source_description=args.source,
                   name=args.name, dry_run=args.dry_run, cwd=args.cwd, force=args.force,
                   source_type=args.source_type, feature=args.feature)
    redacted = f"  [redacted: {', '.join(r['redacted'])}]" if r["redacted"] else ""
    tag = f"group_id={r['group_id']} sha={r['content_hash']}"
    if r["status"] == "dry-run":
        print(f"[dry-run] would write → {tag}{redacted}\n          {r['name']}")
        return 0
    if r["status"] == "duplicate":
        print(f"already remembered (idempotent skip) → {tag}{redacted}")
        return 0
    if r["status"] == "written":
        print(f"remembered → {tag}{redacted}")
        return 0
    print(f"write FAILED ({tag}): {r.get('error','')}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
