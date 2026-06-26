#!/usr/bin/env bash
# test-persist-notable.sh — unit test for compute_notable() in persist-run-artifacts.py (ADR-080 D1).
#
# The notable-artifact filter is a pure list intersection (no FS access), so we
# import it via `python3 -c` and feed it a fixture list of written paths, then
# assert the notable subset. No live run is needed.
#
# Exit 0: all assertions passed. Exit 1: at least one failed.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="${REPO_ROOT}/core/scripts/persist-run-artifacts.py"

if [ ! -f "$SCRIPT" ]; then
  echo "ERROR: persist-run-artifacts.py not found at $SCRIPT" >&2
  exit 2
fi
if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 unavailable" >&2
  exit 2
fi

echo "=== test-persist-notable.sh ==="
echo "SCRIPT: $SCRIPT"
echo

total=0
failures=0

# run_case <name> <written-json-array> <expected-notable-json-array>
run_case() {
  local name="$1" written="$2" expected="$3"
  total=$((total + 1))
  local got
  got=$(SCRIPT_PATH="$SCRIPT" WRITTEN="$written" python3 - <<'PY'
import os, sys, json, importlib.util
spec = importlib.util.spec_from_file_location("persist", os.environ["SCRIPT_PATH"])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
written = json.loads(os.environ["WRITTEN"])
print(json.dumps(mod.compute_notable(written), separators=(",", ":")))
PY
)
  # Compare as sorted JSON for order-insensitivity where the test cares about set,
  # but compute_notable is order-preserving so we compare the exact JSON.
  if [ "$got" = "$expected" ]; then
    echo "PASS: $name"
  else
    failures=$((failures + 1))
    echo "FAIL: $name"
    echo "   expected: $expected"
    echo "   got:      $got"
  fi
}

# --- Case 1: notable classes each match ---
run_case "jam README notable" \
  '["docs/step-2-planning/jam-auth/README.md"]' \
  '["docs/step-2-planning/jam-auth/README.md"]'

run_case "jam index.md notable" \
  '["docs/step-2-planning/jam-auth/index.md"]' \
  '["docs/step-2-planning/jam-auth/index.md"]'

run_case "roadmap.md notable" \
  '["docs/step-3-specs/my-epic/roadmap.md"]' \
  '["docs/step-3-specs/my-epic/roadmap.md"]'

run_case "wave spec notable" \
  '["docs/step-3-specs/my-epic/waves/wave-1-foo/wave-1-foo.md"]' \
  '["docs/step-3-specs/my-epic/waves/wave-1-foo/wave-1-foo.md"]'

run_case "wave prompts notable" \
  '["docs/step-3-specs/my-epic/waves/wave-1-foo/wave-1-foo-prompts.md"]' \
  '["docs/step-3-specs/my-epic/waves/wave-1-foo/wave-1-foo-prompts.md"]'

run_case "ADR notable" \
  '["docs/decisions/ADR-080-deterministic-surfacing-capture-driftlint.md"]' \
  '["docs/decisions/ADR-080-deterministic-surfacing-capture-driftlint.md"]'

run_case "run-log notable" \
  '["docs/step-5-pipeline/2026-06-11/1432-NIMBLE-foo/run-log.md"]' \
  '["docs/step-5-pipeline/2026-06-11/1432-NIMBLE-foo/run-log.md"]'

run_case "locked roadmap notable" \
  '["docs/step-5-pipeline/2026-06-11/1432-ROADMAP-foo/locked.md"]' \
  '["docs/step-5-pipeline/2026-06-11/1432-ROADMAP-foo/locked.md"]'

# --- Case 2: exclusions are filtered out ---
run_case "findings excluded" \
  '["docs/step-5-pipeline/2026-06-11/1432-NIMBLE-foo/findings/implementer.md"]' \
  '[]'

run_case "manifest excluded" \
  '["docs/step-5-pipeline/2026-06-11/1432-NIMBLE-foo/manifest.json"]' \
  '[]'

run_case "run-manifest excluded" \
  '["docs/step-5-pipeline/2026-06-11/1432-NIMBLE-foo/run-manifest.json"]' \
  '[]'

# ADR-087: the one inbox is docs/step-1-ideas/ — ideas (unprefixed) and DEFER- items are scratch funnel,
# never notable. Legacy pre-migration paths stay excluded too (kept until the tree migrates).
run_case "backlog idea excluded" \
  '["docs/step-1-ideas/2026-06-08-thing.md"]' \
  '[]'

run_case "backlog DEFER excluded" \
  '["docs/step-1-ideas/DEFER-2026-06-07-thing.md"]' \
  '[]'

run_case "legacy RAW idea excluded" \
  '["docs/step-1-ideas/RAW-2026-06-08-thing.md"]' \
  '[]'

run_case "legacy OPEN deferral excluded" \
  '["docs/deferrals/OPEN-2026-06-07-thing.md"]' \
  '[]'

run_case "fixture excluded" \
  '["core/scripts/test-fixtures/whatever/run-log.md"]' \
  '[]'

# --- Case 3: mixed list keeps order, dedupes, applies exclusions ---
run_case "mixed list filtered + order preserved" \
  '["docs/step-5-pipeline/2026-06-11/1432-NIMBLE-foo/findings/explore-1.md","docs/decisions/ADR-080-x.md","docs/step-5-pipeline/2026-06-11/1432-NIMBLE-foo/manifest.json","docs/step-5-pipeline/2026-06-11/1432-NIMBLE-foo/run-log.md"]' \
  '["docs/decisions/ADR-080-x.md","docs/step-5-pipeline/2026-06-11/1432-NIMBLE-foo/run-log.md"]'

run_case "dedupe identical paths" \
  '["docs/decisions/ADR-080-x.md","docs/decisions/ADR-080-x.md"]' \
  '["docs/decisions/ADR-080-x.md"]'

# --- Case 4: near-misses that must NOT match ---
run_case "non-ADR docs/decisions file excluded" \
  '["docs/decisions/INDEX.md"]' \
  '[]'

run_case "spec.md (not roadmap/wave) excluded" \
  '["docs/step-5-pipeline/2026-06-11/1432-WAVE-foo/spec.md"]' \
  '[]'

run_case "empty list" \
  '[]' \
  '[]'

# ============================================================================
# AMS-T2 (wave-1-writes) — wire-to-consumer arms for the post-persist memory seam.
#   AC-001: the seam consumes compute_notable()'s output directly — it does NOT
#           re-author the notable-class allowlist (the F-006 drift trap).
#   AC-002: the write helper fires ONCE per notable artifact on a (dry-run) persist,
#           and is idempotent (the ingest CLI / write_fact() de-dupe on re-run).
# ============================================================================

echo
echo "--- AMS-T2 wire-to-consumer ---"

# AC-001: the NEW seam (_write_notable_to_memory) must NOT re-enumerate the notable classes.
# The drift trap (F-006 / ADR-080 D1) is a SECOND allowlist living in the write seam — e.g.
# `if "docs/decisions/" in path` inside _write_notable_to_memory. The single source of truth is
# compute_notable; the seam consumes its OUTPUT. We scope the check to the seam body only
# (def _write_notable_to_memory ... -> next top-level def) — pre-existing notable-class strings
# inside compute_notable (the legitimate source) and unrelated file-write paths elsewhere are not
# duplication.
total=$((total + 1))
dup_hits=$(awk '
  /^def _write_notable_to_memory\(/ {inseam=1; next}
  inseam && /^def [A-Za-z_]+\(/ {inseam=0}
  inseam && /docs\/decisions\/|roadmap\.md|step-3-specs|step-2-planning\/jam-|is_notable[[:space:]]*=/ {print NR": "$0}
' "$SCRIPT")
if [ -z "$dup_hits" ]; then
  echo "PASS: AC-001 write seam does not re-enumerate the notable-class allowlist"
else
  failures=$((failures + 1))
  echo "FAIL: AC-001 notable-class enumeration found INSIDE _write_notable_to_memory (drift trap):"
  echo "$dup_hits"
fi

# AC-002 (a): the seam is actually wired — every persist site calls _write_notable_to_memory.
total=$((total + 1))
sites=$(grep -c '_write_notable_to_memory(' "$SCRIPT")
# 1 definition + 4 call sites = 5 occurrences expected.
if [ "$sites" -ge 5 ]; then
  echo "PASS: AC-002 seam wired at all four persist call sites (occurrences=$sites)"
else
  failures=$((failures + 1))
  echo "FAIL: AC-002 expected >=5 _write_notable_to_memory occurrences (def + 4 sites), got $sites"
fi

# AC-002 (b): fires-once-per-artifact + idempotent on re-run (driven on a --dry-run persist
# so no live graph is needed). We monkeypatch subprocess.run to count ingest invocations and
# _derive_capture_group to a fixed group (so the test is hermetic, independent of the registry).
total=$((total + 1))
got=$(SCRIPT_PATH="$SCRIPT" python3 - <<'PY'
import os, sys, importlib.util
spec = importlib.util.spec_from_file_location("persist", os.environ["SCRIPT_PATH"])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

calls = []
class _FakeResult:
    returncode = 0
    stdout = ""
    stderr = ""
def _fake_run(cmd, *a, **k):
    calls.append(cmd)
    return _FakeResult()
mod.subprocess.run = _fake_run
mod._derive_capture_group = lambda repo_root: "test-group"

notable = [
    "docs/decisions/ADR-099-x.md",
    "docs/step-3-specs/e/roadmap.md",
    "docs/step-5-pipeline/2026-06-13/1200-NIMBLE-x/run-log.md",
]
# dry_run=True bypasses the enable-flag gate (test path), still routes per-artifact.
fired = mod._write_notable_to_memory(notable, "/tmp/repo", dry_run=True)

# Each invocation must target the ingest CLI, carry --group-id, --dry-run, and the artifact path.
ok = (
    fired == len(notable)
    and len(calls) == len(notable)
    and all(any("graphiti-ingest-doc.py" in str(x) for x in c) for c in calls)
    and all("--group-id" in c and "--dry-run" in c for c in calls)
)
# Idempotency contract is enforced downstream by write_fact()'s content-hash gate; here we
# assert the seam itself is deterministic — a second call issues the same per-artifact set.
calls.clear()
mod._write_notable_to_memory(notable, "/tmp/repo", dry_run=True)
ok = ok and len(calls) == len(notable)
print("OK" if ok else f"BAD fired={fired} calls={len(calls)}")
PY
)
if [ "$got" = "OK" ]; then
  echo "PASS: AC-002 write helper fires once per notable artifact (dry-run, hermetic)"
else
  failures=$((failures + 1))
  echo "FAIL: AC-002 fires-once-per-artifact — $got"
fi

# AC-021: off-by-default — with NO enable flag and dry_run=False, the seam no-ops (0 fired).
total=$((total + 1))
got=$(SCRIPT_PATH="$SCRIPT" python3 - <<'PY'
import os, sys, importlib.util
spec = importlib.util.spec_from_file_location("persist", os.environ["SCRIPT_PATH"])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
calls = []
mod.subprocess.run = lambda cmd, *a, **k: calls.append(cmd)
mod._derive_capture_group = lambda repo_root: "test-group"
# A repo root with no graphiti-capture-enabled flag -> disabled -> no-op.
fired = mod._write_notable_to_memory(["docs/decisions/ADR-099-x.md"], "/tmp/no-flag-repo", dry_run=False)
print("OK" if (fired == 0 and not calls) else f"BAD fired={fired} calls={len(calls)}")
PY
)
if [ "$got" = "OK" ]; then
  echo "PASS: AC-021 seam is off-by-default (no enable flag -> no-op)"
else
  failures=$((failures + 1))
  echo "FAIL: AC-021 off-by-default — $got"
fi

echo
echo "=== Summary: $((total - failures))/${total} passed ==="
if [ "$failures" -gt 0 ]; then
  exit 1
fi
exit 0
