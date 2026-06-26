#!/usr/bin/env python3
"""graphiti-cost — read the per-call telemetry JSONL and report calls / tokens / $ spent.

Turns the append-only telemetry sink (written per-LLM-call by routing_gemini_client.py +
the write-path wrap, ADR-074) into a real cost meter — one-shot summary or a live --watch
tail. This is the "see progress, don't guess" tool for graphiti ingestion runs.

  python3 core/scripts/graphiti-cost.py                 # today's totals, by model
  python3 core/scripts/graphiti-cost.py --since 02:00   # only calls after a UTC HH:MM today
  python3 core/scripts/graphiti-cost.py --watch         # live: re-print every 2s as calls land

Prices ($/MTok in,out) — edit if rates change. Source: claude-api skill + Google pricing.
"""
from __future__ import annotations
import argparse, glob, json, os, time
from datetime import datetime, timezone

TELE_DIR = os.path.expanduser(
    os.environ.get("GRAPHITI_TELEMETRY_DIR", "~/graphiti/mcp_server/custom/telemetry"))

PRICES = {  # $ per 1M tokens (input, output)
    "claude-haiku-4-5":      (1.00, 5.00),
    "gemini-2.5-flash":      (0.30, 2.50),
    "gemini-2.5-flash-lite": (0.10, 0.40),
}


def _today_file() -> str:
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return os.path.join(TELE_DIR, f"telemetry-{day}.jsonl")


def _cost(model: str, i: int, o: int) -> float:
    ri, ro = PRICES.get(model, (0.0, 0.0))
    return i / 1e6 * ri + o / 1e6 * ro


def summarize(path: str, since: str | None) -> dict:
    by = {}  # model -> [calls, in, out, cost]
    first = last = None
    groups = set()
    if not os.path.exists(path):
        return {"by": by, "calls": 0, "first": None, "last": None, "groups": groups}
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        ts = r.get("ts", "")
        if since and ts[11:16] < since:  # HH:MM compare within the UTC day
            continue
        m = r.get("model", "?")
        i, o = r.get("input_tokens", 0) or 0, r.get("output_tokens", 0) or 0
        a = by.setdefault(m, [0, 0, 0, 0.0])
        a[0] += 1; a[1] += i; a[2] += o; a[3] += _cost(m, i, o)
        first = first or ts
        last = ts
        if r.get("group_id"):
            groups.add(r["group_id"])
    return {"by": by, "first": first, "last": last, "groups": groups}


def render(path: str, since: str | None) -> str:
    s = summarize(path, since)
    by = s["by"]
    if not by:
        return f"no telemetry yet in {os.path.basename(path)}" + (f" since {since} UTC" if since else "")
    lines = ["%-24s %7s %12s %11s %9s" % ("model", "calls", "in_tok", "out_tok", "$")]
    tc = ti = to = tcost = 0
    for m, (c, i, o, cost) in sorted(by.items(), key=lambda x: -x[1][3]):
        lines.append("%-24s %7d %12d %11d %9.4f" % (m, c, i, o, cost))
        tc += c; ti += i; to += o; tcost += cost
    lines.append("-" * 66)
    lines.append("%-24s %7d %12d %11d %9.4f" % ("TOTAL", tc, ti, to, tcost))
    span = ""
    if s["first"] and s["last"]:
        span = f"  window: {s['first'][11:19]} → {s['last'][11:19]} UTC"
    grp = f"  groups: {', '.join(sorted(s['groups']))}" if s["groups"] else ""
    return "\n".join(lines) + "\n" + span + grp


def main() -> int:
    ap = argparse.ArgumentParser(description="Graphiti telemetry cost meter.")
    ap.add_argument("--since", default=None, help="UTC HH:MM — only count calls after this time today")
    ap.add_argument("--watch", action="store_true", help="live re-print every --interval seconds")
    ap.add_argument("--interval", type=float, default=2.0)
    args = ap.parse_args()
    path = _today_file()
    if not args.watch:
        print(render(path, args.since))
        return 0
    try:
        while True:
            out = render(path, args.since)
            now = datetime.now(timezone.utc).strftime("%H:%M:%S")
            print("\033[2J\033[H", end="")  # clear screen
            print(f"graphiti-cost  (live, {now} UTC)  —  Ctrl-C to stop\n")
            print(out, flush=True)
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print()
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
