#!/usr/bin/env bash
# Wave 4 (ADR-077 D1) — canonical wrapper for the routing-helper unit test.
# pytest is not installed on any host python; the repo convention is stdlib .sh wrappers
# (the prior graphiti suite is .sh). This runs the pure-function seven-case test stdlib-only.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
cd "$REPO_ROOT"
python3 core/scripts/tests/test_routing_gemini_client_ab.py
echo "PASS: test-graphiti-routing-ab.sh"
