#!/usr/bin/env python3
"""graphiti-distill — extract durable, cross-session facts from a session, for automated capture.

The automated-capture half of Wave 4 (the dogfood-gated half — see the dry-run note). It LLM-distills
a session transcript into a few durable facts (NOT the transcript — the noise trap), then routes each
through graphiti_write.write_fact (scrub + fail-closed group_id + idempotent + provenance).

DRY-RUN BY DEFAULT: prints what it WOULD capture and writes nothing. This is the safety valve for the
"curation is unproven" risk — you watch the distillation quality across real sessions and judge it
before trusting it with live writes. `--write` actually writes.

  python3 graphiti-distill.py --transcript /path/to/transcript.jsonl --group-id claude-infra-v2
  python3 graphiti-distill.py --transcript … --group-id … --write     # live (after you trust it)

Uses Anthropic haiku via a plain HTTPS call (no SDK). ANTHROPIC_API_KEY from env or the graphiti .env.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from graphiti_write import _content_hash, write_fact  # noqa: E402
from graphiti_scrubber import scrub  # noqa: E402

GRAPHITI_REPO = (os.environ.get("GRAPHITI_REPO") or next((d for d in (os.path.expanduser("~/graphiti"), os.path.expanduser("~/Desktop/Dev/graphiti"), os.path.expanduser("~/Desktop/Development/graphiti")) if os.path.isdir(d)), os.path.expanduser("~/graphiti")))

# Telemetry sink (graphiti-cost-efficiency Wave 1, ADR-074): one content-free JSONL record per
# Anthropic distill call. Repo-root/.claude/agent-memory/graphiti-telemetry, overridable for tests.
_TELEMETRY_DIR = os.environ.get(
    "GRAPHITI_TELEMETRY_DIR",
    str(Path(__file__).resolve().parents[2] / ".claude" / "agent-memory" / "graphiti-telemetry"),
)


def _record_distill_telemetry(resp, model, group_id, text, t0):
    """Build + append one content-free telemetry record for an Anthropic distill call.

    FAIL-OPEN: the ENTIRE body (scrub, hash, JSON, I/O) is wrapped — telemetry NEVER raises into the
    distill caller. Called after a successful HTTP round-trip (resp parsed); a `usage`-absent response
    is recorded with input/output 0 + an additive `error: "usage_absent"` field (AC-006). The closed
    tuple is the only content (AC-001/AC-007) — no prompt/response body.
    """
    try:
        usage = resp.get("usage") if isinstance(resp, dict) else None
        scrubbed, _ = scrub(text)
        record = {
            "schema_version": "1",
            "ts": datetime.now(timezone.utc).isoformat(),
            "operation": "distill",
            "model": model,
            "lane": "distill",
            "input_tokens": (usage or {}).get("input_tokens", 0),
            "output_tokens": (usage or {}).get("output_tokens", 0),
            "duration_ms": int((time.monotonic() - t0) * 1000),
            "episode_id": None,
            "group_id": group_id,
            "content_hash": _content_hash(group_id or "", scrubbed),
        }
        if usage is None:
            record["error"] = "usage_absent"
        d = Path(_TELEMETRY_DIR)
        d.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        with open(d / f"telemetry-{stamp}.jsonl", "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception as e:  # noqa: BLE001 — telemetry must never break distillation
        print(f"graphiti-distill telemetry: emit failed: {e}", file=sys.stderr)

PROMPT = """You are distilling a work session into DURABLE, cross-session facts worth remembering long-term.

Return ONLY a JSON array of concise fact strings (max {max_facts}). Each fact must be:
- durable (true beyond this session — decisions, architecture, who-owns-what, stable preferences),
- self-contained (understandable without the conversation),
- NOT ephemeral (skip "we just ran X", debugging chatter, todos, pleasantries),
- NOT secrets/credentials/keys (never include them).

If nothing is worth durably remembering, return [].

SESSION:
"""


def _load_dotenv_key(name):
    if os.environ.get(name):
        return os.environ[name]
    env = Path(GRAPHITI_REPO) / "mcp_server" / ".env"
    if env.exists():
        for line in env.read_text(encoding="utf-8").splitlines():
            if line.strip().startswith(f"{name}="):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return None


def _read_transcript(path, max_chars):
    """Read a transcript file (jsonl or text). Keep the tail (most recent) under max_chars."""
    raw = Path(path).read_text(encoding="utf-8", errors="replace")
    # If jsonl, pull text-ish fields; else use raw.
    texts = []
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                obj = json.loads(line)
                texts.append(json.dumps(obj.get("message", obj.get("content", obj)))[:2000])
                continue
            except json.JSONDecodeError:
                pass
        texts.append(line)
    blob = "\n".join(texts)
    return blob[-max_chars:]


def distill(text, model="claude-haiku-4-5", max_facts=8, timeout=30, group_id=None):
    api_key = _load_dotenv_key("ANTHROPIC_API_KEY")
    if not api_key:
        print("graphiti-distill: no ANTHROPIC_API_KEY", file=sys.stderr)
        return []
    body = {
        "model": model, "max_tokens": 1024,
        "messages": [{"role": "user", "content": PROMPT.format(max_facts=max_facts) + text}],
    }
    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages", data=json.dumps(body).encode("utf-8"),
        headers={"x-api-key": api_key, "anthropic-version": "2023-06-01", "content-type": "application/json"},
    )
    t0 = time.monotonic()
    try:
        resp = json.load(urllib.request.urlopen(req, timeout=timeout))
        _record_distill_telemetry(resp, model, group_id, text, t0)  # fail-open; after a successful round-trip
        out = resp["content"][0]["text"].strip()
    except Exception as e:  # noqa: BLE001
        print(f"graphiti-distill: LLM call failed: {e}", file=sys.stderr)
        return []
    # tolerate fences / prose around the array
    start, end = out.find("["), out.rfind("]")
    if start < 0 or end < 0:
        return []
    try:
        facts = json.loads(out[start:end + 1])
    except json.JSONDecodeError:
        return []
    return [f.strip() for f in facts if isinstance(f, str) and f.strip()]


def main() -> int:
    ap = argparse.ArgumentParser(description="Distill a session into durable facts (dry-run by default).")
    ap.add_argument("--transcript", help="path to the session transcript (jsonl/text); else read stdin")
    ap.add_argument("--group-id", default=None, help="explicit group_id (else derived from --cwd, fail-closed)")
    ap.add_argument("--cwd", default=None)
    ap.add_argument("--max-facts", type=int, default=8)
    ap.add_argument("--max-chars", type=int, default=24000, help="transcript tail size fed to the LLM")
    ap.add_argument("--write", action="store_true", help="actually write (default: dry-run)")
    ap.add_argument("--source", default="auto-capture (SessionEnd)")
    # W3IO-T7: optional source-anchor provenance threaded to write_fact (repo-relative path + anchor).
    # Session distillation typically has no single source file (facts span the transcript) -> default
    # None (no stamp); a future doc-grounded caller passes a repo-relative --source-path.
    ap.add_argument("--source-path", default=None,
                    help="repo-relative source path for provenance stamp (e.g. docs/decisions/ADR-076.md)")
    ap.add_argument("--heading-anchor", default=None, help="heading anchor within --source-path")
    args = ap.parse_args()

    text = _read_transcript(args.transcript, args.max_chars) if args.transcript else sys.stdin.read()
    if not text.strip():
        print("graphiti-distill: empty session", file=sys.stderr)
        return 0

    facts = distill(text, max_facts=args.max_facts, group_id=args.group_id)
    if not facts:
        print("graphiti-distill: nothing durable to capture.")
        return 0

    mode = "WRITE" if args.write else "DRY-RUN"
    print(f"graphiti-distill [{mode}]: {len(facts)} candidate fact(s)")
    for f in facts:
        if args.write:
            r = write_fact(f, group_id=args.group_id, source_description=args.source, cwd=args.cwd,
                           source_path=args.source_path, heading_anchor=args.heading_anchor)
            tag = r["status"]
            redacted = f" [redacted: {', '.join(r['redacted'])}]" if r.get("redacted") else ""
            print(f"  [{tag}] {f[:90]}{redacted}  (group_id={r['group_id']})")
        else:
            print(f"  [would-write] {f[:100]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
