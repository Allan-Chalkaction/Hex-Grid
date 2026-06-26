#!/usr/bin/env python3
"""graphiti-ams-read-latency — latency bench for the ambient-memory-surfaces Wave-2 transport swap.

NEW FILE (AMS-T6). Distinct from core/scripts/graphiti-wave2-measure.py, which belongs to the
graphiti-cost-efficiency epic (typed-vs-freeform A/B recall) — the "wave2" collision in the two
filenames is a coincidence across two epics. This script does NOT import, mutate, or repurpose that
script. It measures one thing: the read latency of the swapped HTTP Query API transport in
graphiti-read.py (AMS-T5), versus the recorded docker-exec cypher-shell baseline.

It invokes graphiti-read.py --meter by subprocess and parses the `latency=<ms>` field — it never
reimplements Cypher or the transport (mirrors graphiti-wave2-measure.py:74 READ_SCRIPT invocation).
Runs several warm iterations (the first call may include connection setup) and reports the median.

  python3 graphiti-ams-read-latency.py --group-id claude-infra-v2
  python3 graphiti-ams-read-latency.py --group-id <g> --iterations 7 --emit-jsonl <path>

Exit 0 if the measured HTTP median is materially below the docker baseline (PASS), 1 otherwise.
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
READ_SCRIPT = HERE / "graphiti-read.py"  # the swapped path — invoked, never reimplemented

# Recorded docker-exec cypher-shell baseline. The ~1.2s figure is cypher-shell's JVM cold-start,
# measured 2026-06-08 (documented in the Wave-2 spec / ADR). We cite it as the baseline rather than
# re-timing the now-removed transport; re-timing is impossible once the docker path is gone.
DOCKER_BASELINE_MS = 1200

# "Materially below" threshold: the HTTP median must be under this fraction of the docker baseline.
# The target is ~0.10s (a 12x speedup); we PASS comfortably under half the baseline.
MATERIAL_FRACTION = 0.5

LATENCY_RE = re.compile(r"latency=(\d+)ms")


def measure_once(group_id: str, top_k: int, timeout_s: float) -> int | None:
    """Run graphiti-read.py --meter once; return the reported latency in ms (or None on parse miss)."""
    try:
        out = subprocess.run(
            [sys.executable, str(READ_SCRIPT), "--group-id", group_id,
             "--top-k", str(top_k), "--meter"],
            capture_output=True, text=True, timeout=timeout_s,
        )
    except (subprocess.SubprocessError, OSError):
        return None
    # The meter line is on stderr: "Graphiti-read: ... latency=<ms>ms, group_id=<g>"
    m = LATENCY_RE.search(out.stderr or "")
    return int(m.group(1)) if m else None


def run_bench(group_id: str, top_k: int, iterations: int, timeout_s: float) -> dict:
    """Run a warm bench: one untimed warmup, then `iterations` timed reads; report the median."""
    measure_once(group_id, top_k, timeout_s)  # warmup (connection setup not counted)
    samples: list[int] = []
    for _ in range(iterations):
        ms = measure_once(group_id, top_k, timeout_s)
        if ms is not None:
            samples.append(ms)
        time.sleep(0.02)  # small gap; keep the graph warm without hammering
    median = int(statistics.median(samples)) if samples else None
    passed = median is not None and median < DOCKER_BASELINE_MS * MATERIAL_FRACTION
    return {
        "group_id": group_id,
        "iterations": iterations,
        "samples_ms": samples,
        "http_median_ms": median,
        "docker_baseline_ms": DOCKER_BASELINE_MS,
        "material_threshold_ms": int(DOCKER_BASELINE_MS * MATERIAL_FRACTION),
        "speedup_x": round(DOCKER_BASELINE_MS / median, 1) if median else None,
        "pass": passed,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Latency bench for the AMS Wave-2 HTTP read transport.")
    ap.add_argument("--group-id", required=True)
    ap.add_argument("--top-k", type=int, default=5)
    ap.add_argument("--iterations", type=int, default=7, help="timed warm iterations (a warmup runs first)")
    ap.add_argument("--timeout", type=float, default=10.0, help="per-read subprocess timeout (s)")
    ap.add_argument("--emit-jsonl", default=None, help="append the result as one JSON line to this path")
    args = ap.parse_args()

    result = run_bench(args.group_id, args.top_k, args.iterations, args.timeout)

    if result["http_median_ms"] is None:
        print("AMS read-latency bench: no successful samples (is Neo4j HTTP reachable?)", file=sys.stderr)
        print(json.dumps(result, indent=2))
        return 1

    verdict = "PASS" if result["pass"] else "FAIL"
    print(
        f"AMS read-latency: http_median={result['http_median_ms']}ms "
        f"vs docker_baseline={result['docker_baseline_ms']}ms "
        f"({result['speedup_x']}x speedup) -> {verdict} "
        f"(threshold <{result['material_threshold_ms']}ms)"
    )
    print(json.dumps(result, indent=2))

    if args.emit_jsonl:
        rec = dict(result)
        rec["at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with open(args.emit_jsonl, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")

    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
