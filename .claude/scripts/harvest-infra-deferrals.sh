#!/usr/bin/env bash
# harvest-infra-deferrals.sh — pull infra-tagged deferrals from registered consumer repos into
# claude-infra's OWN backlog inbox (T17). READ-ONLY w.r.t. consumers: it reads each consumer's deferral
# files, copies only the notes tagged `target: claude-infra` into the local inbox, and NEVER writes to or
# deletes from a consumer. Idempotent (matches on a stamped harvest-id).
#
# ADR-087: the local inbox is now docs/step-1-ideas/ and harvested notes land as DEFER-*.md (the merged
# one-pool inbox). Consumers migrate on their own schedule, so the CONSUMER-side scan is DUAL-PATH: it reads
# BOTH the legacy docs/deferrals/OPEN-*.md AND the new docs/step-1-ideas/DEFER-*.md layout — whichever a
# given consumer has — so harvest keeps working across the migration window.
#
# Usage: bash core/scripts/harvest-infra-deferrals.sh
# Output (stdout, last line is machine-parseable): "HARVEST: N new, M skipped, from K consumer(s)"
#
# Zero new primitives: harvested notes are ordinary DEFER-*.md files in the existing docs/step-1-ideas/ folder.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REG="${REPO_ROOT}/core/config/infra-consumers.json"
LOCAL_INBOX="${REPO_ROOT}/docs/step-1-ideas"   # ADR-087: the merged one-pool inbox (was docs/deferrals/)

if ! command -v jq &>/dev/null; then
  echo "harvest: jq required" >&2
  echo "HARVEST: 0 new, 0 skipped, from 0 consumer(s)"
  exit 0
fi
if [ ! -f "$REG" ]; then
  echo "harvest: no consumer registry ($REG) — nothing to harvest"
  echo "HARVEST: 0 new, 0 skipped, from 0 consumer(s)"
  exit 0
fi
mkdir -p "$LOCAL_INBOX"

# Set of harvest-ids already present locally (idempotency) — grep all local files once.
existing_ids="$(grep -rhoE '^- \*\*harvest-id:\*\* .+$' "$LOCAL_INBOX" 2>/dev/null | sed 's/^- \*\*harvest-id:\*\* //' || true)"
has_id() { printf '%s\n' "$existing_ids" | grep -qxF "$1"; }

new=0; skipped=0; consumers=0
count="$(jq -r '.consumers | length' "$REG" 2>/dev/null || echo 0)"
i=0
while [ "$i" -lt "${count:-0}" ]; do
  cpath="$(jq -r ".consumers[$i].path" "$REG" 2>/dev/null)"
  clabel="$(jq -r ".consumers[$i].label // .consumers[$i].path" "$REG" 2>/dev/null)"
  i=$((i + 1))
  [ -z "$cpath" ] && continue
  cpath_exp="${cpath/#\~/$HOME}"
  # ADR-087 dual-path: a consumer may still be on the legacy docs/deferrals/OPEN-* layout, or already
  # migrated to docs/step-1-ideas/DEFER-*. Scan whichever exist (both, if mid-migration).
  cinbox_legacy="${cpath_exp}/docs/deferrals"
  cinbox_new="${cpath_exp}/docs/step-1-ideas"
  if [ ! -d "$cinbox_legacy" ] && [ ! -d "$cinbox_new" ]; then
    # tolerate missing consumer inbox — warn and continue, never fail the sweep
    continue
  fi
  consumers=$((consumers + 1))
  # scan consumer deferral files (read-only) for target: claude-infra — both layouts.
  for f in "$cinbox_legacy"/OPEN-*.md "$cinbox_new"/DEFER-*.md; do
    [ -f "$f" ] || continue
    grep -qE '^- \*\*target:\*\* *claude-infra' "$f" 2>/dev/null || continue
    base="$(basename "$f")"
    hid="${clabel}:${base}"
    if has_id "$hid"; then
      skipped=$((skipped + 1))
      continue
    fi
    # derive a local filename: DEFER-<orig-date>-<label>-<slug>.md (strip whichever source prefix)
    stripped="${base#OPEN-}"; stripped="${stripped#DEFER-}"; stripped="${stripped%.md}"   # e.g. 2026-06-07-some-slug
    labelslug="$(printf '%s' "$clabel" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')"
    if printf '%s' "$stripped" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-'; then
      odate="${stripped:0:10}"; oslug="${stripped:11}"
    else
      odate="$(date +%F)"; oslug="$stripped"
    fi
    out="${LOCAL_INBOX}/DEFER-${odate}-${labelslug}-${oslug}.md"
    # uniquify if needed (different consumer, same date+slug)
    n=2; cand="$out"
    while [ -e "$cand" ]; do cand="${out%.md}-${n}.md"; n=$((n + 1)); done
    out="$cand"
    {
      # prepend provenance + harvest-id, then the original body
      printf '%s\n' "<!-- harvested by harvest-infra-deferrals.sh (T17) — do not edit the provenance lines -->"
      printf -- '- **harvest-id:** %s\n' "$hid"
      printf -- '- **harvested-from:** %s %s\n\n' "$clabel" "$f"
      cat "$f"
    } > "$out"
    new=$((new + 1))
    existing_ids="${existing_ids}"$'\n'"${hid}"   # so a duplicate within the same run also skips
  done
done

echo "HARVEST: ${new} new, ${skipped} skipped, from ${consumers} consumer(s)"
exit 0
