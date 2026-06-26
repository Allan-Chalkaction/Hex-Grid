#!/usr/bin/env bash
# Wave 1 (ADR-098 / ADR-077 D5) — wrapper for the per-arm recall harness test (stdlib; pytest unavailable on host).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$REPO_ROOT"
python3 core/scripts/tests/test_graphiti_eval_arms.py
echo "PASS: test-graphiti-eval-arms.sh"
