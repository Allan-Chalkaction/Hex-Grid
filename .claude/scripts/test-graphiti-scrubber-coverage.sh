#!/usr/bin/env bash
# test-graphiti-scrubber-coverage.sh — W1T-T6 (ADR-074; AC-015, AC-016)
#
# Single-source scrubber invariant: there must be exactly ONE scrub implementation across the
# live graphiti scripts/hooks — the canonical one in core/scripts/graphiti_scrubber.py. Any other
# file under core/scripts/graphiti*.py or core/hooks/*graphiti*.sh that defines its own
# `def scrub(` / `def _scrub(` is parallel-scrubber drift and fails this test.
#
# SELF-TEST (validation procedure — run manually to confirm the guard bites):
#   printf 'def scrub(text):\n    return text, []\n' > core/scripts/_test_parallel_scrubber.py
#   bash core/scripts/test-graphiti-scrubber-coverage.sh   # MUST exit non-zero
#   rm core/scripts/_test_parallel_scrubber.py
#   bash core/scripts/test-graphiti-scrubber-coverage.sh   # back to exit 0
#
# Past-tense docs/ADRs/planning artifacts are NOT live implementations and are excluded by virtue
# of the grep scope (only core/scripts + core/hooks are scanned, never docs/).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Guard scope: ALL top-level core/scripts/*.py (not the tests/ subdir) + the graphiti hooks.
# This is intentionally BROADER than AC-016's example command (`core/scripts/graphiti*.py …`) so a
# parallel scrubber under ANY script name is caught — including the documented self-test stub
# `_test_parallel_scrubber.py`, which the narrower `graphiti*.py` glob would have missed. AC-016's
# command remains valid as a subset of this scope.
matches="$(grep -nE '^\s*def\s+(_?)scrub\s*\(' core/scripts/*.py core/hooks/*graphiti*.sh 2>/dev/null || true)"
count="$(printf '%s' "$matches" | grep -c . || true)"

echo "scrub-def matches (expect exactly 1, in graphiti_scrubber.py):"
printf '%s\n' "$matches" | sed 's/^/  /'

if [ "$count" -ne 1 ]; then
  echo "FAIL: expected exactly 1 scrub definition, found $count (parallel-scrubber drift)." >&2
  exit 1
fi

# And that one match MUST be in the canonical module.
if ! printf '%s' "$matches" | grep -q 'core/scripts/graphiti_scrubber.py:'; then
  echo "FAIL: the single scrub def is not in core/scripts/graphiti_scrubber.py." >&2
  exit 1
fi

# Lightweight content-free check: if any telemetry sink files exist, they must not carry body/prompt
# /messages/candidates/content keys (the AC-001/AC-007 invariant is enforced at emission time by the
# wrap tickets; this is a cheap backstop grep over committed sink samples, if any).
sink_dirs=(".claude/agent-memory/graphiti-telemetry" ".claude/agent-memory/graphiti-manifest")
for d in "${sink_dirs[@]}"; do
  if [ -d "$d" ] && compgen -G "$d/*.jsonl" >/dev/null 2>&1; then
    if grep -lE '"(body|prompt|messages|candidates|content)"' "$d"/*.jsonl 2>/dev/null; then
      echo "FAIL: a telemetry/manifest sink contains a content field (content-free invariant)." >&2
      exit 1
    fi
  fi
done

# --- Wave 3 (W3IO-T9, AC-032): the four new sinks must not regress the no-body invariant. ---
# Locate the graphiti repo: explicit env wins, else probe common $HOME locations.
# Absent everywhere -> the read below fails open and the session continues untouched.
if [ -z "${GRAPHITI_REPO:-}" ]; then
  for _cand in "$HOME/graphiti" "$HOME/Desktop/Dev/graphiti" "$HOME/Desktop/Development/graphiti"; do
    [ -d "$_cand" ] && { GRAPHITI_REPO="$_cand"; break; }
  done
fi
GRAPHITI_REPO="${GRAPHITI_REPO:-$HOME/graphiti}"

# 1+2. Dead-letter + write-lane telemetry JSONL must carry NO body/episode_body/payload key.
w3_globs=(
  ".claude/agent-memory/graphiti-deadletter/deadletter-*.jsonl"
  "$GRAPHITI_REPO/mcp_server/custom/telemetry/telemetry-*.jsonl"
)
for g in "${w3_globs[@]}"; do
  if compgen -G "$g" >/dev/null 2>&1; then
    for f in $g; do
      [ -f "$f" ] || continue
      if grep -qE '"(body|episode_body|payload)"' "$f"; then
        echo "FAIL: $f carries a body/episode_body/payload field (W3IO-T9 no-body invariant)." >&2
        exit 1
      fi
    done
  fi
done

# 3. NEEDS_TRIAGE stderr notification must not leak body content beyond the (scrubbed) name label.
TOKEN="w3t9-bodyleak-canary"
STDERRF="$(mktemp)"; TMP_CWD="$(mktemp -d)"
python3 - "$TOKEN" "$TMP_CWD" 2>"$STDERRF" <<'PY' || true
import sys
sys.path.insert(0, "core/scripts")
from graphiti_write import write_fact
token, cwd = sys.argv[1], sys.argv[2]
write_fact(f"triage label line.\nsecond line {token} body content", group_id=None, cwd=cwd, dry_run=True)
PY
if grep -q "$TOKEN" "$STDERRF"; then
  echo "FAIL: NEEDS_TRIAGE notification leaked body content beyond the name (W3IO-T9)." >&2
  rm -f "$STDERRF"; rm -rf "$TMP_CWD"; exit 1
fi
rm -f "$STDERRF"; rm -rf "$TMP_CWD"

# 4. The source_description stamp must not echo the episode body.
python3 - <<'PY'
import sys
sys.path.insert(0, "core/scripts")
from graphiti_write import write_fact
btok = "w3t9-srcdesc-bodytoken"
r = write_fact(f"{btok} full episode body that must never appear in source_description.",
               group_id="w3-test-scrub", dry_run=True, source_path="docs/x.md")
assert btok not in r["source_description"], f"source_description echoed body: {r['source_description']!r}"
print("OK source_description carries no body")
PY
[ "$?" -ne 0 ] && { echo "FAIL: source_description body-echo check (W3IO-T9)." >&2; exit 1; }

# 5. The scrubber is invoked at exactly ONE call site in the write rail (no parallel unscrubbed path).
# Count REAL call sites only — strip comment lines first so a doc comment that MENTIONS scrub() (e.g. the
# `#   - scrub() runs on EVERY write` invariant note) does not inflate the count (false-positive fixed: the
# count is the executable call rail, not prose). A genuine 2nd code call site is still caught (→ count 2 → FAIL).
scrub_calls="$(grep -vE '^[[:space:]]*#' core/scripts/graphiti_write.py | grep -cE 'scrub\(' || true)"
if [ "${scrub_calls:-0}" -ne 1 ]; then
  echo "FAIL: expected exactly 1 scrub() call site in graphiti_write.py, found ${scrub_calls} (W3IO-T9)." >&2
  exit 1
fi

echo "test-graphiti-scrubber-coverage: OK (single scrub source; no body leak across deadletter/telemetry/NEEDS_TRIAGE/source_description)"
