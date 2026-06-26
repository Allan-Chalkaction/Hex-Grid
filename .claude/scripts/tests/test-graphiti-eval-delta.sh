#!/usr/bin/env bash
# test-graphiti-eval-delta.sh — AMS-T13 (wave-4, AC-014). Wave-verification caller for graphiti-eval's
# token/wall-clock delta + metrics emission, so the eval ACTUALLY FIRES on the wave run (not a dormant
# standalone script). This is the wire-to-consumer atom: it invokes the eval with --measure-delta
# --emit-metrics and asserts the metrics artifact is produced and carries the directional caveat.
#
# Engine-absent / cold graph is EXPECTED and not a failure — the eval is fail-open (always exits 0) and
# the rediscovery arm carries no durable facts on a cold graph; the delta math still runs. This caller
# asserts the WIRING (artifact produced + caveat present), not a recall@k floor (that is AMS-T12's job
# via the leak fixture, NOT this number — AC-016).
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVAL="${SCRIPTS_DIR}/graphiti-eval.py"
TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT
METRICS="${TMPDIR_T}/_metrics.jsonl"

[ -f "$EVAL" ] || { echo "FAIL: graphiti-eval.py not found at $EVAL" >&2; exit 1; }

# Fire the eval with delta + metrics emission (the wired wave-verification invocation).
python3 "$EVAL" --measure-delta --emit-metrics "$METRICS" >/dev/null 2>&1 || true

# AC-013/AC-014: the metrics artifact is produced.
[ -s "$METRICS" ] || { echo "FAIL: metrics artifact not produced at $METRICS" >&2; exit 1; }
echo "  [ok] metrics artifact produced ($METRICS)"

# AC-013: the record carries the measured token/wall-clock delta fields.
python3 - "$METRICS" <<'PY'
import json, sys
rec = json.loads(open(sys.argv[1], encoding="utf-8").read().splitlines()[-1])
d = rec.get("delta") or {}
for k in ("mean_injected_tokens", "mean_read_wall_ms", "token_delta_inject_saves", "loop_pays",
          "coherence_budget_tokens_per_turn"):
    assert k in d, f"delta missing field {k!r}: {d}"
assert d["coherence_budget_tokens_per_turn"] == 680, "coherence-budget ceiling not 680/turn"
assert "overall_recall_at_k" in rec, "metrics record missing recall@k"
print("  [ok] delta fields present (token + wall-clock measured against the coherence budget)")
PY

# AC-016: the directional-vs-release-gate caveat is present and unambiguous.
if ! grep -qiE "directional" "$METRICS"; then echo "FAIL: caveat missing 'directional'" >&2; exit 1; fi
if ! grep -qiE "AMS-T12|leak fixture" "$METRICS"; then echo "FAIL: caveat missing the AMS-T12 release-gate pointer" >&2; exit 1; fi
if ! grep -qiE "12-case|unratified" "$METRICS"; then echo "FAIL: caveat missing the 12-case/unratified note" >&2; exit 1; fi
echo "  [ok] directional-vs-release-gate caveat present (12-case/unratified; gate is AMS-T12)"

echo "test-graphiti-eval-delta: OK"
exit 0
