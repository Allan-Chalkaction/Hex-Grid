#!/usr/bin/env bash
# test-graphiti-lockstate.sh — GCE-T4 (AC-010, AC-012, AC-018a, AC-019)
# Unit test for the additive lock-state index (derive_lock_state, lockstate_decision,
# record/lookup JSONL discipline, single-source hash, reference-only record shape).
# Bash wrapper over stdlib python (pytest is unavailable on the host — mirrors test-graphiti-manifest.sh).
set -euo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

GRAPHITI_LOCKSTATE_DIR="$TMPDIR_T" python3 - "$SCRIPTS_DIR" "$TMPDIR_T" <<'PY'
import sys, os, json, inspect
from datetime import datetime, timezone
sys.path.insert(0, sys.argv[1])
import graphiti_lockstate as ls

ldir = sys.argv[2]

# 1. derive_lock_state: taxonomy folder drives the enum (AC-010).
assert ls.derive_lock_state("docs/step-6-done/2026-06-13/foo.md") == "locked", "step-6-done -> locked"
assert ls.derive_lock_state("docs/step-6-done/handoffs/x.md") == "locked", "step-6-done/** -> locked"
assert ls.derive_lock_state("docs/step-1-ideas/2026-06-13-x.md") == "unlocked", "step-1-ideas -> unlocked"
assert ls.derive_lock_state("docs/step-1-backlog/legacy.md") == "unlocked", "step-1-backlog (legacy) -> unlocked"
assert ls.derive_lock_state("docs/step-2-planning/jam-x/README.md") == "in-progress", "step-2-* -> in-progress"
assert ls.derive_lock_state("docs/step-3-specs/epic/roadmap.md") == "in-progress", "step-3-* -> in-progress"
assert ls.derive_lock_state("docs/step-5-pipeline/2026-06-13/run/prompt.md") == "in-progress", "step-4-* -> in-progress"
print("  [ok] derive_lock_state taxonomy: locked / unlocked / in-progress")

# 2. record/lookup round-trips on the SAME JSONL discipline as graphiti_manifest (UTC daily, lazy mkdir).
ls.record("docs/step-6-done/a.md", "hash0000aaaa0000", "locked", "2026-06-13T00:00:00Z")
got = ls.lookup("docs/step-6-done/a.md")
assert got == {"content_hash": "hash0000aaaa0000", "lock_state": "locked", "ts": "2026-06-13T00:00:00Z"}, got
print("  [ok] record/lookup round-trip:", got)

# 3. miss returns None.
assert ls.lookup("docs/step-6-done/never.md") is None, "unseen path -> None"
print("  [ok] miss -> None")

# 4. AC-018a: the recorded JSONL line has EXACTLY the four reference keys (no body/episode_body/scrubbed).
today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
day_file = os.path.join(ldir, f"lockstate-{today}.jsonl")
assert os.path.exists(day_file), f"expected {day_file}"
with open(day_file) as fh:
    first = json.loads(fh.readline())
assert set(first.keys()) == {"path", "content_hash", "lock_state", "ts"}, first.keys()
assert "body" not in first and "episode_body" not in first and "scrubbed" not in first
print("  [ok] AC-018a record has exactly 4 reference keys:", sorted(first.keys()))

# 5. lockstate_decision (AC-012): unchanged locked doc -> skip, changed locked doc -> supersede.
#    A locked path already recorded with hash0000aaaa0000 above.
assert ls.lockstate_decision("docs/step-6-done/a.md", "hash0000aaaa0000") == "skip", "unchanged locked -> skip"
assert ls.lockstate_decision("docs/step-6-done/a.md", "DIFFERENThash99") == "supersede", "changed locked -> supersede"
# first-time locked path -> create; non-locked (unlocked/in-progress) -> create (defers to manifest gate).
assert ls.lockstate_decision("docs/step-6-done/brand-new.md", "anyhash00000000") == "create", "first locked -> create"
assert ls.lockstate_decision("docs/step-1-ideas/idea.md", "anyhash00000000") == "create", "unlocked -> create"
assert ls.lockstate_decision("docs/step-3-specs/s.md", "anyhash00000000") == "create", "in-progress -> create"
print("  [ok] lockstate_decision: skip / supersede / create")

# 6. AC-019 single-source hash: the module imports the canonical helper and defines NO local hash.
src = inspect.getsource(ls)
assert ("from graphiti_write import _content_hash" in src
        or "graphiti_manifest.content_hash" in src), "must import the single-source content hash"
# No EXECUTABLE hashlib use: neither `import hashlib` nor a `hashlib.`/`sha256(` call. Prose mentions
# of the word "hashlib" in the docstring are fine; we assert on the code patterns, not the bare word.
assert "import hashlib" not in src, "lockstate module must NOT import hashlib"
assert "hashlib." not in src, "lockstate module must NOT call hashlib"
assert "sha256(" not in src, "lockstate module must NOT call sha256 directly"
print("  [ok] AC-019 single-source hash imported; no local hash computation")

print("PASS")
PY

# 7. AC-011 grep invariant: NO new line-level-delta MACHINERY (code) in core/scripts/ python modules.
#    We scope to the *.py modules (not these tests, which legitimately reference the pattern) and
#    discard prose/docstring mentions of the deferral (lines naming the Round-3 deferral or "deferred").
DELTA_HITS="$(grep -rnE 'delta.reingest|graph.delta|invalid_at' "$SCRIPTS_DIR"/graphiti_*.py "$SCRIPTS_DIR"/graphiti-*.py 2>/dev/null \
  | grep -vE 'deferred|Round-3|risk-cap|NO line-level|no line-level' || true)"
if [ -n "$DELTA_HITS" ]; then
  echo "  [FAIL] unexpected line-level-delta machinery present (AC-011):"; echo "$DELTA_HITS"; exit 1
else
  echo "  [ok] AC-011 no line-level-delta machinery in graphiti_*.py modules"
fi

# 8. AC-010 derivation grep invariant: the taxonomy markers are present in the lockstate source.
grep -nE 'step-6-done|step-1-ideas|lock_state' "$SCRIPTS_DIR/graphiti_lockstate.py" >/dev/null \
  && echo "  [ok] AC-010 lock_state derivation present" \
  || { echo "  [FAIL] no lock_state taxonomy derivation"; exit 1; }

echo "test-graphiti-lockstate: OK"
