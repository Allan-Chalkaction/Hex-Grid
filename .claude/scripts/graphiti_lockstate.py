#!/usr/bin/env python3
"""graphiti_lockstate — the additive lock-state index, layered ON the manifest ledger.

This module adds a lock-state DIMENSION to the already-shipped `(content_hash, group_id)`
idempotency substrate (`graphiti_manifest.py`). It does NOT fork the ledger format and it does
NOT define a second content-hash implementation:

  - The lock-state record `{path, content_hash, lock_state, ts}` rides the SAME append-only
    UTC-daily JSONL discipline as the manifest (`record`/`lookup` shape, lazy mkdir, newest-first
    scan) — mirroring `graphiti_manifest.py` lines ~38–82. The only differences are the sink
    sub-directory (`graphiti-lockstate/` vs `graphiti-manifest/`) and the record keys.
  - The content hash is the SINGLE source: imported from `graphiti_write._content_hash`
    (re-exported as `graphiti_manifest.content_hash`). This module computes NO hash of its own —
    there is no `hashlib`/`sha256` here (AC-019 single-source invariant).

NO SCHEMA MIGRATION: the lock-state field is additive on append-only JSONL (ADR-068 discipline),
reversible by file deletion. There is no SQL table, no backfill, no RLS — absent records simply
mean "not yet recorded" and the consumer falls back to existing manifest behavior (forward-safe).

Lock-state derivation (AC-010) is PURE — path (+ git as a tiebreaker) in, enum out — so it is
unit-testable without a graph or container. Location is authoritative (ADR-087 location-is-status):

  docs/step-6-done/**                       -> 'locked'      (the doc has reached done)
  docs/step-1-ideas/** (or step-1-backlog)  -> 'unlocked'    (the inbox; ADR-089 rename)
  docs/step-2-*/  step-3-*/  step-4-*/      -> 'in-progress' (intermediate pipeline)

`lockstate_decision(path, content_hash)` is the consumer-facing API GCE-T3 calls to choose
skip-vs-supersede-vs-create. It COMPOSES with (does not replace) `graphiti_manifest.lookup` (the
primary idempotency gate) and `graphiti_write._already_written` (the Neo4j fast-path). On a
content-hash change for a LOCKED doc it resolves to 'supersede': the changed content has a NEW
content_hash, so `graphiti_manifest.lookup` MISSES and `write_fact` takes the CREATE arm, writing a
fresh episode — Graphiti's bi-temporal model then invalidates the contradicted prior facts. Supersession
is native/temporal, NOT a manifest `update_uuid` rewrite (a changed hash never hits the manifest UPDATE
arm). Whole-doc-supersede, NOT a new line-level-delta machine (line-level delta-reingest is deferred to
Round-3 per ADR-097 risk-cap).

Security invariant (AC-018a): NO body / episode_body / scrubbed prose ever enters a lock-state
record. The record carries exactly the four reference keys {path, content_hash, lock_state, ts}.
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
# Single-source content hash (AC-019): re-exported by graphiti_manifest from graphiti_write.
# This module imports it ONLY so callers have a hash available without a parallel impl; it never
# computes a hash of its own (no hashlib here).
from graphiti_write import _content_hash  # noqa: E402  (single-source helper)

content_hash = _content_hash  # re-export the canonical hash; no local computation.

# Lock-state ledger directory: repo-root/.claude/agent-memory/graphiti-lockstate, overridable for
# tests via GRAPHITI_LOCKSTATE_DIR (mirrors graphiti_manifest's GRAPHITI_MANIFEST_DIR override).
_DEFAULT_DIR = Path(__file__).resolve().parents[2] / ".claude" / "agent-memory" / "graphiti-lockstate"


def _lockstate_dir() -> Path:
    return Path(os.environ.get("GRAPHITI_LOCKSTATE_DIR", str(_DEFAULT_DIR)))


def _today_file(d: Path) -> Path:
    # UTC daily filename rotation — same shape as graphiti_manifest (lockstate-YYYY-MM-DD.jsonl).
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return d / f"lockstate-{stamp}.jsonl"


def derive_lock_state(path: str) -> str:
    """Derive the lock state for a doc PATH from the live folder taxonomy (ADR-087/089).

    Location is authoritative (ADR-087 location-is-status); the on-disk folder name decides:
      - a path under  docs/step-6-done/**            -> 'locked'
      - a path under  docs/step-1-ideas/** (or the legacy step-1-backlog) -> 'unlocked'
      - a path under  docs/step-2-* / step-3-* / step-4-*  -> 'in-progress'
    Anything else (no recognized pipeline folder) defaults to 'unlocked' — forward-safe: an
    unknown location is treated as not-yet-locked, so the flow falls back to ordinary idempotency.

    PURE: path string in, enum out — no graph, no container, no I/O. Git is the tiebreaker only
    when location is genuinely ambiguous (a moved doc); on-disk location is resolved FIRST, so the
    current taxonomy folder wins (a taxonomy-folder move IS a lock-state change). We normalize on
    the posix-style path so the match is OS-independent.
    """
    # A path key may carry a chunk discriminator ("<repo-rel>#<heading-anchor>") so a multi-chunk doc
    # has one lock-state record per chunk; taxonomy derivation uses the file path, so strip the anchor.
    p = str(path).split("#", 1)[0].replace("\\", "/")
    # step-6-done is the locked sink (handoffs/, sessions/, specs/, jams/, deferrals/ all under it).
    if "step-6-done" in p:
        return "locked"
    # the inbox: ADR-089 renamed step-1-backlog -> step-1-ideas; match either (forward-safe fallback).
    if "step-1-ideas" in p or "step-1-backlog" in p:
        return "unlocked"
    # intermediate pipeline folders are unlocked-in-progress (post-renumber, ADR-127:
    # step-2-planning, step-3-specs, step-4-queue, step-5-pipeline are all in-flight stages;
    # step-6-done is the locked terminal, already handled above).
    if "step-2-" in p or "step-3-" in p or "step-4-" in p or "step-5-" in p:
        return "in-progress"
    return "unlocked"


def record(path: str, content_hash: str, lock_state: str, ts: str) -> None:
    """Append one lock-state record to today's UTC daily file (lazy mkdir -p).

    `path` is the lock-state KEY: a repo-relative doc path, optionally suffixed with a chunk
    discriminator ("<repo-rel>#<heading-anchor>") so a multi-chunk doc tracks each section's content
    independently. `derive_lock_state` strips the anchor for taxonomy derivation.

    SECURITY (AC-018a): exactly the four reference keys {path, content_hash, lock_state, ts}.
    NO body / episode_body / scrubbed prose. content_hash is the reference, never the content.
    """
    d = _lockstate_dir()
    d.mkdir(parents=True, exist_ok=True)
    rec = {"path": path, "content_hash": content_hash, "lock_state": lock_state, "ts": ts}
    with open(_today_file(d), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")


def lookup(path: str) -> dict | None:
    """Return the newest lock-state record for PATH, else None.

    Files are scanned newest-first (filename sorted descending); within a file, lines are scanned
    top-to-bottom and the first match wins (mirrors graphiti_manifest.lookup). The returned dict is
    the last-recorded {content_hash, lock_state, ts} for the path — used to decide whether the
    content changed since the last ingest.
    """
    d = _lockstate_dir()
    if not d.is_dir():
        return None
    for f in sorted(d.glob("lockstate-*.jsonl"), reverse=True):
        try:
            with open(f, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if rec.get("path") == path:
                        return {"content_hash": rec.get("content_hash"),
                                "lock_state": rec.get("lock_state"),
                                "ts": rec.get("ts")}
        except OSError:
            continue
    return None


def lockstate_decision(path: str, content_hash: str) -> str:
    """Decide skip-vs-supersede-vs-create for a doc at PATH carrying CONTENT_HASH.

    Returns one of:
      'skip'      — a LOCKED doc whose content is UNCHANGED since the last recorded ingest
                    (same content_hash on the newest lock-state record). The consumer skips it.
      'supersede' — a LOCKED doc whose content CHANGED (a prior lock-state record exists for the
                    path but with a DIFFERENT content_hash). The new hash misses the manifest dedup, so
                    write_fact CREATEs a fresh episode and Graphiti's bi-temporal invalidation supersedes
                    the prior facts — NOT a manifest update_uuid rewrite. NO line-level-delta machinery.
      'create'    — first-time ingest of this path, OR a non-locked (unlocked / in-progress) doc.
                    The consumer proceeds normally; the manifest gate still dedups identical content.

    This is the consumer-facing API GCE-T3 consults in the real ingest path (AC-012 wire-to-consumer).
    It COMPOSES with the manifest gate — it does not replace it: an unlocked doc returns 'create' and
    the existing `(content_hash, group_id)` manifest/Neo4j idempotency still skips an exact duplicate.
    """
    lock_state = derive_lock_state(path)
    if lock_state != "locked":
        # unlocked / in-progress docs follow ordinary idempotency (manifest gate handles dedup).
        return "create"
    prior = lookup(path)
    if prior is None:
        return "create"  # first time we've seen this locked path
    if prior.get("content_hash") == content_hash:
        return "skip"     # unchanged locked doc — no re-ingest
    return "supersede"    # changed locked doc — new hash → CREATE a fresh episode + bi-temporal invalidation


if __name__ == "__main__":
    # tiny CLI: `graphiti_lockstate.py decide <path> <content_hash>` | `derive <path>`
    if len(sys.argv) == 4 and sys.argv[1] == "decide":
        print(lockstate_decision(sys.argv[2], sys.argv[3]))
    elif len(sys.argv) == 3 and sys.argv[1] == "derive":
        print(derive_lock_state(sys.argv[2]))
    else:
        print("usage: graphiti_lockstate.py {decide <path> <content_hash> | derive <path>}",
              file=sys.stderr)
        sys.exit(2)
