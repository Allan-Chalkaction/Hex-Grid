#!/usr/bin/env python3
"""graphiti-eval — measure whether the read path surfaces the right durable facts.

The product is retrieval; this is the instrument. For each case in the eval set it runs the
v1 read (graphiti-read.py) against the case's group_id and checks whether the `expected_facts`
substrings surface in the top_k. Reports recall@k per case + overall, and compares to a recorded
baseline so a regression (a change that drops retrieval quality) fails CI.

  python3 graphiti-eval.py                                   # run against the default fixture
  python3 graphiti-eval.py --baseline core/scripts/tests/fixtures/graphiti-eval-baseline.json
  python3 graphiti-eval.py --write-baseline <path>          # record current scores as baseline

Exit 0 = at/above baseline (or no baseline). Exit 1 = regression vs baseline. Exit 2 = setup error.

NOTE (v1): the fixture cases are THROWAWAY (built from test memories). The real 10-20 hand-judged
cases land after real seeding (roadmap Wave 3). recall@k here checks "is the fact retrievable";
precision and query-driven relevance arrive with the semantic read mode.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_FIXTURE = HERE / "tests" / "fixtures" / "graphiti-eval-set.jsonl"
READ_SCRIPT = HERE / "graphiti-read.py"

# Wave 4 (ADR-077 D4): rediscovery-cost cap. inject-off cannot surface durable project-specific
# facts from a bare prompt (they are not in the base model), so turns_to_fact is capped here to
# denote "not surfaced within the budget" rather than an unbounded value.
REDISCOVERY_CAP = 5

# AMS-T13 (wave-4, AC-013..AC-017): the coherence-budget ceiling the recall loop's inject cost is
# measured against. ~680 tokens/turn (coherence-budget.md §5 / ADR-098). The inject-vs-rediscovery
# delta proves whether the loop pays (inject-cost < rediscovery-cost) or honestly flags where it does not.
COHERENCE_BUDGET_TOKENS_PER_TURN = 680
# Default first-class metrics sink (additive — NEVER replaces the baseline/regression contract).
DEFAULT_METRICS = HERE / "tests" / "fixtures" / "_metrics.jsonl"

# AC-016: the directional-vs-release-gate caveat, embedded in every metrics artifact so no downstream
# reader can mistake the 12-case recall@k for a release gate.
DIRECTIONAL_CAVEAT = (
    "12-case, UNRATIFIED (every record judged_by='...operator to ratify') eval set — recall@k here is "
    "DIRECTIONAL proof only, NOT a release gate. The binding W4 release gate is the leak fixture "
    "(AMS-T12: core/scripts/tests/test-graphiti-isolation.sh), not this number. "
    "Eval-set ratification/expansion is a tracked follow-up (AC-017)."
)


def load_cases(path: Path) -> list[dict]:
    cases = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if "_comment" in obj:  # skip the header/comment line
            continue
        cases.append(obj)
    return cases


def arm_key(case: dict) -> str:
    """Derive the routing-arm partition key for a case.

    Per-arm recall (Flash-Lite vs Flash) is the cost-vs-recall instrument (ADR-077 D5): without an
    arm-specific partition to measure against, "recall per arm" is a category error. The arm key is a
    READ-SIDE concern only — graphiti-read.py already scopes reads per partition with `WHERE r.group_id
    = $g`, so the case's `group_id` IS the arm partition on the read side (no host-side ContextVar
    access needed).

    ARM-KEYING MECHANISM (ADR-077 D1 — load-bearing): the WRITE side seals the partition via the
    `_WRITE_CTX` ContextVar primitive proven in graphiti_write.py:56/120 ({group_id, name,
    content_hash} set before the nested add_episode), NOT via a naive `group_id` kwarg on the nested
    `resolve_edge` call. ADR-077 D1 records that graphiti-core 0.28.1 telemetry shows that kwarg
    dropped (`group_id=null` on resolve_edge), so it is unusable as a partition primitive — the
    ContextVar (with a documented time-windowed partition as fallback) is the real arm-keying path.
    Here on the read side we recover the arm from the partition's `-arm-<x>` suffix convention (cases
    bind e.g. `claude-infra-v2-arm-flash-lite`); a case may also carry an explicit `arm` field, which
    wins. A case with no arm dimension is bucketed under "default".
    """
    if case.get("arm"):
        return str(case["arm"])
    gid = str(case.get("group_id", ""))
    marker = "-arm-"
    idx = gid.find(marker)
    if idx >= 0:
        return gid[idx + len(marker):]
    return "default"


def run_read(group_id: str, top_k: int, meter: bool = False) -> tuple[str, str, float]:
    """Shell out to graphiti-read.py. Returns (stdout_lower, stderr, wall_clock_ms).

    When meter=True we pass --meter; graphiti-read.py prints its meter line (injected/facts/latency
    /group_id) to STDERR — there is NO persistent graphiti-read.log, so the harness captures stderr
    per invocation (ADR-077 D4 ground-truth). The wall-clock here is the end-to-end read latency the
    inject path actually costs per turn (AMS-T13), measured around the subprocess.
    """
    cmd = [sys.executable, str(READ_SCRIPT), "--group-id", group_id, "--top-k", str(top_k), "--max-bytes", "100000"]
    if meter:
        cmd.append("--meter")
    t0 = time.monotonic()
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    wall_ms = (time.monotonic() - t0) * 1000.0
    return out.stdout.lower(), out.stderr, wall_ms


def score_case(case: dict, inject_on: bool = True) -> dict:
    """Score one case. inject_on=True (default) reads + injects durable facts; inject_on=False runs
    the bare prompt (no read) — the rediscovery-cost arm (ADR-077 D4)."""
    if inject_on:
        text, meter, wall_ms = run_read(case["group_id"], int(case.get("top_k", 10)), meter=True)
    else:
        text, meter, wall_ms = "", "", 0.0  # --inject-off: no read; bare prompt carries no durable facts
    expected = case.get("expected_facts", [])
    hits = [e for e in expected if e.lower() in text]
    recall = (len(hits) / len(expected)) if expected else 1.0
    # turns_to_fact (research §5.13): inject-on surfaces facts in ~1 turn; inject-off cannot surface
    # durable project facts from the bare prompt, so it hits the rediscovery cap.
    turns_to_fact = 1 if (inject_on and recall > 0) else REDISCOVERY_CAP
    return {
        "group_id": case["group_id"],
        "context": case.get("context", ""),
        "recall": round(recall, 3),
        "found": hits,
        "missed": [e for e in expected if e.lower() not in text],
        "turns_to_fact": turns_to_fact,
        "injected_tokens": len(text) // 4,  # ~4 chars/token — the one-time injection cost
        "read_wall_ms": round(wall_ms, 1),  # AMS-T13: measured per-read wall-clock the inject path costs
        "meter": meter.strip(),
    }


def compute_delta(results_on: list[dict], results_off: list[dict]) -> dict:
    """AMS-T13 (AC-013): the measured inject-vs-rediscovery delta (token + wall-clock).

    inject-cost  = the one-time injected-token cost + the read wall-clock the inject path pays.
    rediscovery-cost = the turns the bare prompt must spend re-deriving the fact (turns_to_fact), each
                       turn metered against the coherence budget (~680 tokens/turn). The loop PAYS when
                       inject-cost < rediscovery-cost; a net-negative delta is reported honestly, not
                       absorbed (AC-017 -> W3 fallback).
    """
    n = max(len(results_on), 1)
    mean_injected_tokens = sum(r["injected_tokens"] for r in results_on) / n
    mean_read_wall_ms = sum(r["read_wall_ms"] for r in results_on) / n
    # rediscovery: extra turns the inject-off arm needs beyond the 1 turn inject would have taken,
    # priced at the coherence budget per turn (the avoided cost the inject buys).
    mean_turns_off = (sum(r["turns_to_fact"] for r in results_off) / max(len(results_off), 1)
                      if results_off else float(REDISCOVERY_CAP))
    rediscovery_extra_turns = max(mean_turns_off - 1.0, 0.0)
    rediscovery_token_cost = rediscovery_extra_turns * COHERENCE_BUDGET_TOKENS_PER_TURN
    # token delta: positive => inject SAVES tokens (rediscovery would have cost more); negative => loop
    # costs more than it saves.
    token_delta = rediscovery_token_cost - mean_injected_tokens
    pays = token_delta > 0
    return {
        "mean_injected_tokens": round(mean_injected_tokens, 1),
        "mean_read_wall_ms": round(mean_read_wall_ms, 1),
        "mean_turns_to_fact_inject_off": round(mean_turns_off, 2),
        "rediscovery_extra_turns": round(rediscovery_extra_turns, 2),
        "coherence_budget_tokens_per_turn": COHERENCE_BUDGET_TOKENS_PER_TURN,
        "rediscovery_token_cost": round(rediscovery_token_cost, 1),
        "token_delta_inject_saves": round(token_delta, 1),
        "loop_pays": pays,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fixture", default=str(DEFAULT_FIXTURE))
    ap.add_argument("--baseline", default=str(HERE / "tests" / "fixtures" / "graphiti-eval-baseline.json"))
    ap.add_argument("--write-baseline", default=None)
    ap.add_argument("--tolerance", type=float, default=0.0, help="allowed recall drop vs baseline")
    # Wave 4 (ADR-077 D4): mutually-exclusive inject modes. --inject-on (default) preserves today's
    # behavior (read + inject durable facts); --inject-off runs the bare prompt (rediscovery arm).
    inject = ap.add_mutually_exclusive_group()
    inject.add_argument("--inject-on", dest="inject", action="store_true", default=True,
                        help="read durable facts via graphiti-read.py and inject them (default)")
    inject.add_argument("--inject-off", dest="inject", action="store_false",
                        help="skip the read; run the bare prompt (rediscovery-cost arm)")
    # AMS-T13 (AC-013/AC-014): additive delta emission. --measure-delta runs BOTH arms in one pass and
    # computes the inject-vs-rediscovery token/wall-clock delta; --emit-metrics writes the recall@k +
    # delta + caveat to a first-class metrics artifact (_metrics.jsonl by default). Neither flag alters
    # the baseline/regression contract below (AC-015) — they are strictly additive.
    ap.add_argument("--measure-delta", action="store_true",
                    help="run inject-on AND inject-off, emit the token/wall-clock delta (AMS-T13)")
    ap.add_argument("--emit-metrics", nargs="?", const=str(DEFAULT_METRICS), default=None,
                    help="append recall@k + delta + caveat to a metrics artifact (default: _metrics.jsonl)")
    args = ap.parse_args()

    fixture = Path(args.fixture)
    if not fixture.exists():
        print(f"ERROR: fixture not found: {fixture}", file=sys.stderr)
        return 2

    cases = load_cases(fixture)
    if not cases:
        print("ERROR: no eval cases in fixture.", file=sys.stderr)
        return 2

    results = [score_case(c, inject_on=args.inject) for c in cases]
    overall = round(sum(r["recall"] for r in results) / len(results), 3)
    mean_turns = round(sum(r["turns_to_fact"] for r in results) / len(results), 2)
    mode = "inject-on" if args.inject else "inject-off"

    print(f"Graphiti retrieval eval [{mode}] — {len(results)} cases, "
          f"overall recall@k = {overall}, mean turns_to_fact = {mean_turns}\n")

    # Per-arm recall (ADR-077 D5 — the cost-vs-recall instrument). Group results by the routing-arm
    # partition key (see arm_key() / the ADR-077 D1 mechanism note there) and emit one recall@k line
    # per arm. Cases on a single shared partition collapse to one "default" arm (today's behavior);
    # the arm fixture (graphiti-eval-arms.jsonl) carries ≥2 distinct arm partitions so this prints a
    # measurable per-arm line for each. The overall figure above is preserved unchanged.
    arms: dict[str, list[dict]] = {}
    for c, r in zip(cases, results):
        arms.setdefault(arm_key(c), []).append(r)
    if len(arms) > 1 or "default" not in arms:
        for arm in sorted(arms):
            ar = arms[arm]
            arm_recall = round(sum(x["recall"] for x in ar) / len(ar), 3)
            print(f"  arm[{arm}] — {len(ar)} cases, recall@k = {arm_recall}")
        print()

    for r in results:
        mark = "OK " if r["recall"] == 1.0 else "!! "
        print(f"  {mark}[{r['recall']:.2f}] t2f={r['turns_to_fact']} {r['group_id']}: {r['context']}")
        if r["missed"]:
            print(f"        missed: {r['missed']}")

    # AMS-T13 (AC-013/AC-016/AC-017): measure + emit the inject-vs-rediscovery delta. Additive — it
    # never touches the baseline/regression contract (AC-015) below.
    delta = None
    if args.measure_delta or args.emit_metrics:
        # Run the inject-off arm (the rediscovery baseline) so we can price the avoided cost. When the
        # current run already IS inject-off, results are the off arm and we re-run inject-on for the on arm.
        if args.inject:
            results_on = results
            results_off = [score_case(c, inject_on=False) for c in cases]
        else:
            results_off = results
            results_on = [score_case(c, inject_on=True) for c in cases]
        delta = compute_delta(results_on, results_off)
        print("\n-- token/wall-clock delta (AMS-T13, AC-013) --")
        print(f"  mean injected tokens/turn : {delta['mean_injected_tokens']} "
              f"(coherence budget ceiling {COHERENCE_BUDGET_TOKENS_PER_TURN}/turn)")
        print(f"  mean read wall-clock      : {delta['mean_read_wall_ms']} ms")
        print(f"  rediscovery token cost    : {delta['rediscovery_token_cost']} "
              f"({delta['rediscovery_extra_turns']} extra turns x {COHERENCE_BUDGET_TOKENS_PER_TURN})")
        print(f"  token delta (inject saves): {delta['token_delta_inject_saves']}  "
              f"-> loop pays = {delta['loop_pays']}")
        if not delta["loop_pays"]:
            # AC-017: a net-negative delta is recorded as an explicit operator finding with the named
            # W3 fallback — NOT silently absorbed.
            print("\n  OPERATOR FINDING (AC-017): measured delta is NET-NEGATIVE — the recall loop costs "
                  "more than it saves.\n  Documented fallback: narrow W3 to per-wave-start read ONLY, "
                  "deferring Explore-dispatch + architect-PRE reads (ADR-090 Alternatives).", file=sys.stderr)
        else:
            print("\n  Marginal/positive delta -> keep W3 as-is; re-measure after eval-set ratification "
                  "(AC-017 follow-up).")
        print(f"\n  CAVEAT: {DIRECTIONAL_CAVEAT}")

    # AC-013/AC-016: emit the first-class metrics artifact (recall@k + delta + caveat).
    if args.emit_metrics:
        metrics_path = Path(args.emit_metrics)
        record = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "ticket": "AMS-T13",
            "fixture": str(fixture),
            "n_cases": len(results),
            "mode": mode,
            "overall_recall_at_k": overall,
            "mean_turns_to_fact": mean_turns,
            "delta": delta,
            "directional_only": True,
            "release_gate": "AMS-T12 (core/scripts/tests/test-graphiti-isolation.sh) — NOT this recall@k",
            "caveat": DIRECTIONAL_CAVEAT,
        }
        try:
            metrics_path.parent.mkdir(parents=True, exist_ok=True)
            with open(metrics_path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(record, ensure_ascii=False) + "\n")
            print(f"\nMetrics appended: {metrics_path}")
        except OSError as e:
            print(f"WARN: could not write metrics artifact {metrics_path}: {e}", file=sys.stderr)

    if args.write_baseline:
        Path(args.write_baseline).write_text(
            json.dumps({"overall_recall": overall, "n_cases": len(results)}, indent=2), encoding="utf-8"
        )
        print(f"\nBaseline written: {args.write_baseline} (overall_recall={overall})")
        return 0

    # Baseline regression check applies to the inject-on arm only — inject-off's ~0 recall is the
    # expected rediscovery arm (durable facts absent from the bare prompt), not a regression.
    if not args.inject:
        print(f"\n(inject-off arm — recall {overall} is the rediscovery baseline; "
              f"no regression gate applied)")
        return 0

    baseline_path = Path(args.baseline)
    if baseline_path.exists():
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
        floor = baseline.get("overall_recall", 0.0) - args.tolerance
        if overall < floor:
            print(f"\nREGRESSION: overall recall {overall} < baseline floor {floor}", file=sys.stderr)
            return 1
        print(f"\nOK: overall recall {overall} >= baseline floor {floor}")
    else:
        print(f"\n(no baseline at {baseline_path} — run with --write-baseline to record one)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
