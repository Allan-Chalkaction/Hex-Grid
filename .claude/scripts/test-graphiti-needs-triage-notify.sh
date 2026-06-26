#!/usr/bin/env bash
# test-graphiti-needs-triage-notify.sh — write-time NEEDS_TRIAGE stderr notification (W3IO-T6, AC-029).
#
# Host-only (NO docker): a write whose cwd is outside the derivation root resolves fail-closed to the
# quarantine sink. dry_run=True so no real write happens — the notification must STILL fire (it's
# emitted before the dry-run/write decision). Assert EXACTLY ONE NEEDS_TRIAGE line in the expected
# format, and that NO scrubbed-body substring leaks into it.
set -uo pipefail
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP_CWD="$(mktemp -d)"   # outside ~/Desktop/Development/projects-active -> derive_group_id -> quarantine
STDERR_FILE="$(mktemp)"
trap 'rm -rf "$TMP_CWD" "$STDERR_FILE"' EXIT

# A distinctive token placed on a NON-first line (so it is NOT part of the episode `name`, which is
# the first line). The notification legitimately carries `name=` (the ≤80-char, already-scrubbed
# first-line label — consistent with T5's dead-letter episode_name); the invariant under test is that
# the BODY BEYOND the name is never dumped into the notification.
BODY_TOKEN="zzqq-secret-body-marker-9173"

SCRIPTS_DIR="$SCRIPTS_DIR" TMP_CWD="$TMP_CWD" BODY_TOKEN="$BODY_TOKEN" python3 - 2>"$STDERR_FILE" <<'PY'
import os, sys
sys.path.insert(0, os.environ["SCRIPTS_DIR"])
from graphiti_write import write_fact
# group_id=None + cwd outside the derivation root -> fail-closed quarantine resolution.
# First line is the harmless label; the secret token is on a LATER line (must not leak).
body = f"Triage probe label line.\nSecond line {os.environ['BODY_TOKEN']} body content beyond the name."
r = write_fact(body, group_id=None, cwd=os.environ["TMP_CWD"], dry_run=True)
# resolved gid must be the quarantine sink for this test to be meaningful.
assert "NEEDS_TRIAGE" in r["group_id"], f"expected quarantine resolution, got {r['group_id']!r}"
PY
rc=$?
[ "$rc" -ne 0 ] && { echo "FAIL: write_fact quarantine probe (rc=$rc)" >&2; cat "$STDERR_FILE" >&2; exit 1; }

# Exactly one NEEDS_TRIAGE line, correct format.
matches="$(grep -cE '^NEEDS_TRIAGE: group_id=\S+ content_hash=[0-9a-f]{16} name=' "$STDERR_FILE" || true)"
[ "${matches:-0}" -eq 1 ] || { echo "FAIL: expected exactly 1 NEEDS_TRIAGE line, got ${matches:-0}" >&2; cat "$STDERR_FILE" >&2; exit 1; }

# No body leak: the distinctive body token must NOT appear anywhere in the notification stderr.
if grep -q "$BODY_TOKEN" "$STDERR_FILE"; then
  echo "FAIL: SECURITY — scrubbed-body token leaked into the NEEDS_TRIAGE notification" >&2
  exit 1
fi

echo "test-graphiti-needs-triage-notify: OK (one notification, no body leak)"
