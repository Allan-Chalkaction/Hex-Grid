#!/usr/bin/env bash
#
# metrics-summary.sh — read-side counterpart to measure-run.sh.
#
# Reads docs/step-3-specs/_metrics.jsonl, filters records tagged {"kind":"measurement"},
# and prints a compact text table grouped by version (v1 / v2 / unknown) with,
# per group: run count plus median and mean of:
#   output_tokens
#   operator_interrupts
#   agent_dispatches
#
# Records whose value for a given metric is null/missing are EXCLUDED from that
# metric's aggregate (not counted as zero). The per-metric sample count is
# annotated when it differs from the group's run count.
#
# Legacy {slug,status,timestamp} records (no "kind" field) and malformed JSON
# lines are skipped silently — measure-run.sh tags its records so legacy
# consumers ignore them and so this consumer can pick them out.
#
# Pure-read: this script never writes to or mutates _metrics.jsonl. It writes
# only to stdout/stderr.
#
# Usage:
#   metrics-summary.sh                        # summarize <repo>/docs/step-3-specs/_metrics.jsonl
#   metrics-summary.sh --metrics <path>       # summarize an explicit file
#   metrics-summary.sh --task <slug>          # restrict to records whose task contains <slug>
#   metrics-summary.sh --json                 # emit grouped aggregates as JSON to stdout
#                                             # (composes with --metrics / --task)
#   metrics-summary.sh -h | --help            # this help
#
# JSON output shape (when --json is passed):
#   {
#     "<version>": {
#       "runs": N,
#       "output_tokens":       {"median": M, "mean": A, "n": K},
#       "operator_interrupts": {"median": M, "mean": A, "n": K},
#       "agent_dispatches":    {"median": M, "mean": A, "n": K}
#     },
#     ...
#   }
# Per-metric null-skip semantics match the table output: records missing a
# given metric are excluded from that metric's median/mean and the "n" field
# reflects the actual sample count. When a metric has no samples in a group,
# median and mean are null and n is 0 (shape is stable across groups).
# Empty / absent metrics file or zero matching records -> "{}" and exit 0.
#
# Exit codes:
#   0  success (including: file absent or empty -> "no measurement records found",
#      or "{}" in --json mode)
#   1  argument error or unknown flag
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

METRICS="$REPO_DIR/docs/step-3-specs/_metrics.jsonl"
TASK_FILTER=""
JSON_OUT=0

die() { printf 'metrics-summary: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --metrics) [ $# -ge 2 ] || die "--metrics needs a path"; METRICS="$2"; shift 2 ;;
    --task)    [ $# -ge 2 ] || die "--task needs a slug";    TASK_FILTER="$2"; shift 2 ;;
    --json)    JSON_OUT=1; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;  # dynamic: header comment block (no hardcoded line range)
    *) die "unknown arg: $1" ;;
  esac
done

# Empty / absent metrics file -> graceful exit 0.
# In --json mode emit "{}" so the output is always valid JSON; in table mode
# print a human-readable notice.
if [ ! -f "$METRICS" ] || [ ! -s "$METRICS" ]; then
  if [ "$JSON_OUT" -eq 1 ]; then
    echo "{}"
  else
    echo "no measurement records found (metrics file: $METRICS)"
  fi
  exit 0
fi

python3 - "$METRICS" "$TASK_FILTER" "$JSON_OUT" <<'PY'
import json, sys
from statistics import median, mean

path, task_filter, json_out_flag = sys.argv[1], sys.argv[2], sys.argv[3]
json_out = (json_out_flag == "1")

GROUPS = ("v1", "v2", "unknown")
# duration_seconds (T11 — measure-run.sh) added to the tuple so the existing
# --json aggregator surfaces it with the same null-skip + {median,mean,n} shape
# (T13 /telemetry consumes it through this single aggregator — no second parser).
METRICS = ("output_tokens", "operator_interrupts", "agent_dispatches", "duration_seconds")

buckets = {g: [] for g in GROUPS}

with open(path, encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if not isinstance(o, dict):
            continue
        if o.get("kind") != "measurement":
            continue
        if task_filter:
            t = o.get("task")
            if not isinstance(t, str) or task_filter not in t:
                continue
        v = o.get("version")
        group = v if v in ("v1", "v2") else "unknown"
        buckets[group].append(o)

# Drop empty groups from the output.
populated = [(g, buckets[g]) for g in GROUPS if buckets[g]]

if not populated:
    if json_out:
        # Stable shape: empty/zero-matching always emits "{}" + exit 0.
        print("{}")
    else:
        print("no measurement records found (file had 0 matching records)")
    sys.exit(0)

def fmt_num(x):
    # Integers render as integers; non-integers get one decimal place.
    if x == int(x):
        return str(int(x))
    return f"{x:.1f}"

def aggregate(records, key):
    samples = [r.get(key) for r in records if isinstance(r.get(key), (int, float))]
    if not samples:
        return None, None, 0
    return median(samples), mean(samples), len(samples)

# --- JSON branch -------------------------------------------------------------
# When --json is set, emit the grouped aggregates as one compact JSON object
# to stdout and exit. Per-metric shape is always {median, mean, n} — when no
# samples exist for a metric, median and mean are null and n is 0. Numeric
# values are emitted as JSON numbers (no string-formatting / no "-" sentinel).
if json_out:
    result = {}
    for group, recs in populated:
        entry = {"runs": len(recs)}
        for key in METRICS:
            med, avg, n = aggregate(recs, key)
            entry[key] = {"median": med, "mean": avg, "n": n}
        result[group] = entry
    print(json.dumps(result))
    sys.exit(0)

# --- Table branch (default) --------------------------------------------------
# Build rows: [version, runs, <per-metric (median, mean, n) triple for each key in METRICS>...]
# Tuple-length-driven so adding a metric to METRICS extends the table without a
# hardcoded column-index edit (T13 added duration_seconds).
rows = []
for group, recs in populated:
    runs = len(recs)
    row = [group, str(runs)]
    for key in METRICS:
        med, avg, n = aggregate(recs, key)
        if med is None:
            row.extend(["-", "-", n])
        else:
            row.extend([fmt_num(med), fmt_num(avg), n])
    rows.append(row)

# Per-metric cell: "<median> / <mean>" with " (n=<k>)" suffix when k != runs.
def cell(med, avg, n, runs):
    base = f"{med} / {avg}"
    if med == "-":
        return f"- / -" + (f" (n={n})" if n != runs else "")
    if n != runs:
        return f"{base} (n={n})"
    return base

# Build display rows — one "<metric> (med/mean)" column per METRICS key.
display = []
header = ["version", "runs"] + [f"{key} (med/mean)" for key in METRICS]
display.append(header)
for r in rows:
    version, runs = r[0], r[1]
    runs_int = int(runs)
    cells = []
    for i in range(len(METRICS)):
        base = 2 + i * 3
        cells.append(cell(r[base], r[base + 1], r[base + 2], runs_int))
    display.append([version, runs] + cells)

# Column widths.
widths = [max(len(row[i]) for row in display) for i in range(len(header))]

def render(row):
    return "  ".join(row[i].ljust(widths[i]) for i in range(len(row)))

print(render(display[0]))
print("  ".join("-" * widths[i] for i in range(len(header))))
for row in display[1:]:
    print(render(row))

PY
