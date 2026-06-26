#!/usr/bin/env python3
"""graphiti-cost-ab-summarize — per-arm resolve_edge token-cost summary for the Wave 4 A/B.

Standalone, stdlib-only (ADR-077 D3 — NOT an extension of graphiti-eval.py, which is the recall
harness). Reads the Wave-1 telemetry JSONL sink line-by-line (ADR-068 discipline), filters
`operation == 'dedupe_edges.resolve_edge'`, groups by group_id prefix
(`ab-wave4-flash-lite-*` = treatment vs `ab-wave4-flash-*` = control), and reports mean/median/min/max
of `input_tokens + output_tokens` per call and per consecutive-episode burst.

  python3 graphiti-cost-ab-summarize.py                       # today's UTC file
  python3 graphiti-cost-ab-summarize.py --date 2026-06-10
  python3 graphiti-cost-ab-summarize.py --glob 'telemetry-2026-06-*.jsonl'

NOTE (Wave 4 finding): graphiti-core 0.28.1 does NOT forward group_id to the resolve_edge LLM call
(edge_operations.py:556 omits it), so resolve_edge telemetry records carry group_id=null and the
per-partition A/B cannot populate the arms without a graphiti-core patch. This script reports the
empty arms honestly (N=0) rather than fabricating a signal — that N=0 is the INDETERMINATE evidence.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import statistics
import sys
from datetime import datetime, timezone

DEFAULT_DIR = os.environ.get(
    "GRAPHITI_TELEMETRY_DIR_HOST",
    os.path.expanduser("~/graphiti/mcp_server/custom/telemetry"),
)
FLASH_LITE_PREFIX = "ab-wave4-flash-lite-"
FLASH_PREFIX = "ab-wave4-flash-"
BURST_WINDOW_S = 30.0  # consecutive records on one group_id within this ts window = one episode burst


def _iter_records(paths: list[str]):
    for p in paths:
        try:
            with open(p, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        yield json.loads(line)
                    except json.JSONDecodeError:
                        continue  # skip malformed line defensively (ADR-068)
        except OSError:
            continue


def _arm(group_id) -> str | None:
    if not isinstance(group_id, str):
        return None
    # flash-lite checked first: ab-wave4-flash-lite-* also literally starts with ab-wave4-flash-
    if group_id.startswith(FLASH_LITE_PREFIX):
        return "flash-lite"
    if group_id.startswith(FLASH_PREFIX):
        return "flash"
    return None


def _stats(vals: list[int]) -> str:
    if not vals:
        return "N=0  (no resolve_edge records on this arm)"
    return (f"N={len(vals)}  mean={statistics.mean(vals):.0f}  median={statistics.median(vals):.0f}  "
            f"min={min(vals)}  max={max(vals)}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=DEFAULT_DIR)
    ap.add_argument("--date", default=None, help="YYYY-MM-DD (default: today UTC)")
    ap.add_argument("--glob", default=None, help="glob within --dir (overrides --date)")
    args = ap.parse_args()

    if args.glob:
        paths = sorted(glob.glob(os.path.join(args.dir, args.glob)))
    else:
        date = args.date or datetime.now(timezone.utc).strftime("%Y-%m-%d")
        paths = [os.path.join(args.dir, f"telemetry-{date}.jsonl")]

    arms: dict[str, list[int]] = {"flash-lite": [], "flash": []}
    # per-arm bursts: list of (group_id, ts_epoch) to fold into episode bursts
    seq: dict[str, list[tuple[str, float]]] = {"flash-lite": [], "flash": []}
    total_resolve = 0
    null_gid_resolve = 0

    for r in _iter_records(paths):
        if r.get("operation") != "dedupe_edges.resolve_edge":
            continue
        total_resolve += 1
        gid = r.get("group_id")
        if gid is None:
            null_gid_resolve += 1
        arm = _arm(gid)
        if arm is None:
            continue
        tot = (r.get("input_tokens") or 0) + (r.get("output_tokens") or 0)
        arms[arm].append(tot)
        try:
            ts = datetime.fromisoformat(r["ts"]).timestamp()
            seq[arm].append((gid, ts))
        except (KeyError, ValueError):
            pass

    print(f"# Wave 4 resolve_edge cost A/B — files: {', '.join(os.path.basename(p) for p in paths)}\n")
    print(f"resolve_edge records scanned: {total_resolve}  "
          f"(of which group_id=null: {null_gid_resolve})\n")
    print("Per-call input_tokens+output_tokens:")
    print(f"  flash-lite (treatment): {_stats(arms['flash-lite'])}")
    print(f"  flash      (control):   {_stats(arms['flash'])}\n")

    # episode-burst grouping (research-fidelity; per-call stats are the binding measurement)
    for arm in ("flash-lite", "flash"):
        bursts = 0
        last_gid, last_ts = None, None
        for gid, ts in sorted(seq[arm], key=lambda x: x[1]):
            if gid != last_gid or last_ts is None or (ts - last_ts) > BURST_WINDOW_S:
                bursts += 1
            last_gid, last_ts = gid, ts
        print(f"  {arm} episode-bursts (≤{BURST_WINDOW_S:.0f}s window): {bursts}")

    if null_gid_resolve == total_resolve and total_resolve > 0:
        print("\n⚠️  ALL resolve_edge records carry group_id=null — the propagation seam "
              "(edge_operations.py:556) is unresolved; per-partition arms cannot populate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
