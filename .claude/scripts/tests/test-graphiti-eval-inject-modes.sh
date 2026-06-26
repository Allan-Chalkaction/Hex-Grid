#!/usr/bin/env bash
# Wave 4 (ADR-077 D4) — wrapper for the inject-on/inject-off harness test (stdlib; pytest unavailable on host).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$REPO_ROOT"
python3 core/scripts/tests/test_graphiti_eval_inject_modes.py
echo "PASS: test-graphiti-eval-inject-modes.sh"
