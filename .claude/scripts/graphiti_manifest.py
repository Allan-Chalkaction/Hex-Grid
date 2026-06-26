#!/usr/bin/env python3
"""graphiti_manifest — the unified (content_hash, group_id) manifest ledger.

Wave 1 (graphiti-cost-efficiency) ships the API ONLY; the ledger stays empty until
Wave 3 wires the writers into the write path (the deterministic-uuid create-vs-update
branch — Wave 0 V4 RED mitigation, ADR-073). `lookup()` against an empty ledger
correctly returns None.

Two functions:
  record(content_hash, group_id, episode_uuid, ts) -> None
      Append one JSON line to  <manifest_dir>/manifest-YYYY-MM-DD.jsonl  (UTC daily file).
  lookup(content_hash, group_id) -> {"episode_uuid", "ts"} | None
      Scan manifest-*.jsonl NEWEST-FIRST (filename descending); first match wins.

Append-only JSONL with UTC daily rotation (ADR-068 discipline; no size-based rotation).
The content-hash helper is imported from graphiti_write — there is exactly ONE content-hash
implementation across the graphiti_*.py modules (AC-009/AC-016 single-source invariant); this
module defines NO local hash function.

Wave 2 (bulk-ingest-lockstate, ADR-098) layers an ADDITIVE lock-state index ON this ledger:
`graphiti_lockstate.py` records `(path, content_hash, lock_state)` using the SAME append-only
UTC-daily JSONL discipline (`record`/`lookup` shape, lazy mkdir, newest-first scan) in a sibling
sink dir, and re-uses THIS module's `content_hash` re-export — it does NOT fork the ledger format
and computes no hash of its own. NO schema migration: the lock-state field is additive on
append-only JSONL, reversible by file deletion (ADR-068).
"""
from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from graphiti_write import _content_hash  # noqa: E402  (single-source helper; re-exported below)

# Re-export so callers have ONE import site for the canonical hash (no parallel impl).
content_hash = _content_hash

# Manifest directory: repo-root/.claude/agent-memory/graphiti-manifest, overridable for tests.
_DEFAULT_DIR = Path(__file__).resolve().parents[2] / ".claude" / "agent-memory" / "graphiti-manifest"


def _manifest_dir() -> Path:
    return Path(os.environ.get("GRAPHITI_MANIFEST_DIR", str(_DEFAULT_DIR)))


def _today_file(d: Path) -> Path:
    # UTC daily filename rotation (AC-018). strftime('%Y-%m-%d') -> manifest-2026-06-09.jsonl
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return d / f"manifest-{stamp}.jsonl"


def record(content_hash: str, group_id: str, episode_uuid: str, ts: str) -> None:
    """Append one manifest record to today's UTC daily file (lazy mkdir -p)."""
    d = _manifest_dir()
    d.mkdir(parents=True, exist_ok=True)
    rec = {"content_hash": content_hash, "group_id": group_id,
           "episode_uuid": episode_uuid, "ts": ts}
    with open(_today_file(d), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")


def lookup(content_hash: str, group_id: str) -> dict | None:
    """Return {'episode_uuid', 'ts'} for the newest record matching BOTH keys, else None.

    Files are scanned newest-first (filename sorted descending); within a file, lines are
    scanned top-to-bottom and the first match is returned. None if no match in any file.
    """
    d = _manifest_dir()
    if not d.is_dir():
        return None
    for f in sorted(d.glob("manifest-*.jsonl"), reverse=True):
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
                    if rec.get("content_hash") == content_hash and rec.get("group_id") == group_id:
                        return {"episode_uuid": rec.get("episode_uuid"), "ts": rec.get("ts")}
        except OSError:
            continue
    return None


if __name__ == "__main__":
    # tiny CLI: `graphiti_manifest.py lookup <hash> <group_id>`
    if len(sys.argv) == 4 and sys.argv[1] == "lookup":
        print(json.dumps(lookup(sys.argv[2], sys.argv[3])))
    else:
        print("usage: graphiti_manifest.py lookup <content_hash> <group_id>", file=sys.stderr)
        sys.exit(2)
