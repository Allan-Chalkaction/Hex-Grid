#!/usr/bin/env bash
# D4 / ADR-015 § Q-D1 Sub-mechanism 1a — Layer 1 drift surface.
#
# Non-LLM check that runs at the top of each per-ticket iteration in the
# wave-level-redesign loop, BEFORE t-implement fires. Gated by
# wave_protocol_version == 2 at the calling site.
#
# Four checks (all must pass for VERDICT: CONSISTENT):
#   1. Approved deferrals targeting current ticket are anticipated by
#      the wave-spec's per-ticket AC brief.
#   2. (ADR-017 amended) Two tickets cannot both NEW the same file. When
#      `tickets[i].new_files` is populated for both the current ticket and
#      a prior `complete` ticket, compare NEW-only intersections. When
#      `new_files` is absent on either side of a pair, fall back to the
#      pre-amendment strict planned_files comparison (preserves legacy
#      behavior for v2 manifests authored before ADR-017).
#   3. Wave-level disposition for current ticket is GO or REVIEW-PER-TICKET.
#   4. Wave-manifest hasn't been structurally mutated since wave-start
#      (compare against the snapshot w-cto-consensus wrote).
#
# Dependencies: jq (used in Checks 1/2/3/4 — hard substrate dependency).
#
# Usage:
#   drift-check.sh <wave_run_dir> <current_ticket> <ticket_run_dir>
#
# Output:
#   Writes ${ticket_run_dir}/findings/drift-check.md with all DRIFTED messages
#   (or empty body if all pass) and the verdict line as the last non-empty line.
#   Echoes the verdict to stdout.
#
# Exit codes:
#   0 = always (the verdict line is the disposition signal; non-zero exits
#       would be hook-error territory which is out of scope here).

set -uo pipefail

WAVE_RUN_DIR="$1"
CURRENT_TICKET="$2"
TICKET_RUN_DIR="$3"

if [ -z "$WAVE_RUN_DIR" ] || [ -z "$CURRENT_TICKET" ] || [ -z "$TICKET_RUN_DIR" ]; then
  echo "ERROR: drift-check.sh requires <wave_run_dir> <current_ticket> <ticket_run_dir>" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFERRALS_PY="${REPO_ROOT}/core/scripts/wave-deferrals.py"
MANIFEST="${WAVE_RUN_DIR}/wave-manifest.json"
WAVE_SPEC="${WAVE_RUN_DIR}/wave-spec.md"
SNAPSHOT="${WAVE_RUN_DIR}/wave-manifest-at-wave-start.json"

mkdir -p "${TICKET_RUN_DIR}/findings"
OUT="${TICKET_RUN_DIR}/findings/drift-check.md"

# Fresh write — overwrite any prior drift-check.md from earlier iterations.
{
  echo "# Drift check — ${CURRENT_TICKET}"
  echo ""
  echo "**Run at:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "**Wave run dir:** ${WAVE_RUN_DIR}"
  echo ""
} > "$OUT"

DRIFTED=0
DRIFT_MESSAGES=()

# ---------------------------------------------------------------------------
# Step 0 — Auto-fold approved deferrals into reader surfaces (ADR-021 Cluster C)
# ---------------------------------------------------------------------------
# Fires BEFORE Check 1 so the four checks operate on augmented artifacts.
# Idempotent — second invocation detects the PROMPT_HEADING literal and skips.
# Surfaces: wave-spec.md, ticket-spec.md, ticket-prompt.md.
echo "## Step 0 — Auto-fold (ADR-021)" >> "$OUT"
echo "" >> "$OUT"

if [ ! -f "${WAVE_RUN_DIR}/deferrals.json" ]; then
  echo "Skipped: no deferrals.json (wave has no approved deferrals yet)." >> "$OUT"
  echo "" >> "$OUT"
else
  # Auto-fold candidate paths. The wave-level spec uses v2 location
  # (${wave_run_dir}/spec.md) per FU-3 / ADR-015; v1 fallback to wave-spec.md
  # (the older location) for backward compat. The auto-fold helper silently
  # skips missing files, so we can pass both candidates.
  WAVE_SPEC_V2="${WAVE_RUN_DIR}/spec.md"
  WAVE_SPEC_V1="${WAVE_RUN_DIR}/wave-spec.md"
  WAVE_SPEC_PATH=""
  if [ -f "$WAVE_SPEC_V2" ]; then
    WAVE_SPEC_PATH="$WAVE_SPEC_V2"
  elif [ -f "$WAVE_SPEC_V1" ]; then
    WAVE_SPEC_PATH="$WAVE_SPEC_V1"
  fi
  TICKET_SPEC_PATH="${TICKET_RUN_DIR}/spec.md"
  TICKET_PROMPT_PATH="${TICKET_RUN_DIR}/prompt.md"

  FOLD_OUTPUT=$(python3 "$DEFERRALS_PY" auto-fold \
      "${WAVE_RUN_DIR}/deferrals.json" \
      "$CURRENT_TICKET" \
      ${WAVE_SPEC_PATH:+--wave-spec-path "$WAVE_SPEC_PATH"} \
      --ticket-spec-path "$TICKET_SPEC_PATH" \
      --ticket-prompt-path "$TICKET_PROMPT_PATH" \
      2>&1 || echo "{}")

  if [ "$FOLD_OUTPUT" = "{}" ]; then
    echo "No pending deferrals targeting ${CURRENT_TICKET}; no auto-fold performed." >> "$OUT"
  else
    echo "Auto-fold result:" >> "$OUT"
    echo '```json' >> "$OUT"
    echo "$FOLD_OUTPUT" >> "$OUT"
    echo '```' >> "$OUT"
  fi
  echo "" >> "$OUT"
fi

# ---------------------------------------------------------------------------
# Check 1 — Approved deferrals targeting current ticket are anticipated by the
# wave-spec's per-ticket AC brief.
# ---------------------------------------------------------------------------
echo "## Check 1 — Approved deferrals anticipated" >> "$OUT"
echo "" >> "$OUT"

if [ ! -f "${WAVE_RUN_DIR}/deferrals.json" ]; then
  echo "Skipped: no deferrals.json (wave has no proposed deferrals yet)." >> "$OUT"
  echo "" >> "$OUT"
elif [ ! -f "$WAVE_SPEC" ]; then
  echo "Skipped: wave-spec.md not present at ${WAVE_SPEC} (wave-pm-spec did not run; v1 wave?)." >> "$OUT"
  echo "" >> "$OUT"
else
  # Read approved entries targeting current ticket. pending_for returns a JSON
  # array of approved-but-not-yet-resolved deferrals (per wave-deferrals.py
  # docstring; F-007 split landed pre-D1).
  APPROVED_JSON=$(python3 "$DEFERRALS_PY" pending-for "${WAVE_RUN_DIR}/deferrals.json" "$CURRENT_TICKET" 2>/dev/null || echo "[]")

  # Extract the per-ticket section from wave-spec.md for keyword matching. Stop the
  # section at the next ticket header OR at the ADR-021 auto-fold block
  # ("## Deferred from prior tickets"). Step 0 above folds approved deferrals into THIS
  # same spec before Check 1 runs; for the last ticket in the file that block falls
  # inside its section, so including it would make every approved deferral look
  # "anticipated" (the check would match the very deferral Step 0 just wrote in) and
  # defeat the check. Anticipation is judged against the ORIGINAL brief only.
  AC_BRIEF=$(awk -v key="$CURRENT_TICKET" '
    $0 ~ "^### TICKET-KEY:[[:space:]]*"key"[[:space:]]*$" { in_section=1; next }
    in_section && /^### TICKET-KEY:/ { in_section=0 }
    in_section && /^## Deferred from prior tickets/ { in_section=0 }
    in_section { print }
  ' "$WAVE_SPEC")

  COUNT=$(echo "$APPROVED_JSON" | jq 'length')
  if [ "$COUNT" = "0" ]; then
    echo "No approved deferrals target ${CURRENT_TICKET}. Pass." >> "$OUT"
    echo "" >> "$OUT"
  else
    UNANTICIPATED=0
    # F-011a normalization (ADR-021 / INFRA-024): strip backticks + leading/
    # trailing whitespace before comparing ledger summaries to AC-brief prose.
    # Wave 3 surfaced this gap when the manual-augment prose used `path` but
    # the ledger stored bare `path` — keyword-match failed false-positively.
    # Normalize both sides symmetrically.
    NORMALIZED_AC_BRIEF=$(echo "$AC_BRIEF" | sed -e 's/`//g')
    while IFS= read -r row; do
      DF_ID=$(echo "$row" | jq -r .id)
      SUMMARY=$(echo "$row" | jq -r .summary)
      # Keyword-overlap heuristic: take a 50-char prefix of the summary; case-
      # insensitive match against the AC brief. Refine if synthetic testing
      # shows false positives.
      NORMALIZED_SUMMARY=$(echo "$SUMMARY" | sed -e 's/`//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      KEY_PREFIX=$(echo "$NORMALIZED_SUMMARY" | head -c 50)
      if ! echo "$NORMALIZED_AC_BRIEF" | grep -qiF "$KEY_PREFIX" 2>/dev/null; then
        echo "DRIFTED: deferral-not-anticipated ${DF_ID}: ${SUMMARY}" >> "$OUT"
        DRIFT_MESSAGES+=("Check 1: deferral-not-anticipated ${DF_ID}")
        DRIFTED=1
        UNANTICIPATED=$((UNANTICIPATED + 1))
      fi
    done < <(echo "$APPROVED_JSON" | jq -c '.[]')
    if [ "$UNANTICIPATED" = "0" ]; then
      echo "All ${COUNT} approved deferrals targeting ${CURRENT_TICKET} are anticipated by the wave-spec brief." >> "$OUT"
    fi
    echo "" >> "$OUT"
  fi
fi

# ---------------------------------------------------------------------------
# Check 2 (ADR-017 amended) — Two tickets cannot both NEW the same file.
#
# When both the current ticket and a prior `complete` ticket carry a
# populated `new_files` field, intersect the NEW-only sets. Non-empty
# intersection is drift.
#
# When `new_files` is absent on either side of a pair (legacy v1 manifests,
# or v2 manifests authored before ADR-017), fall back per-pair to the
# pre-amendment strict planned_files disjointness comparison. This preserves
# backward-compatibility for un-migrated waves; the fallback decision is
# per-pair, not per-manifest, so mixed-mode (some tickets declare new_files,
# others don't) is supported.
# ---------------------------------------------------------------------------
echo "## Check 2 — Files-already-newed (new_files disjointness; ADR-017)" >> "$OUT"
echo "" >> "$OUT"

if [ ! -f "$MANIFEST" ]; then
  echo "Skipped: wave-manifest.json not present." >> "$OUT"
  echo "" >> "$OUT"
else
  CURRENT_NF=$(jq -r --arg key "$CURRENT_TICKET" \
    '.tickets[] | select(.key == $key) | .new_files // [] | .[]' "$MANIFEST" | sort -u)
  CURRENT_PF=$(jq -r --arg key "$CURRENT_TICKET" \
    '.tickets[] | select(.key == $key) | .planned_files[]' "$MANIFEST" | sort -u)
  # Presence check uses `has("new_files")` — `null` and missing both map to
  # "0", any actual array (including the explicit `[]`) maps to "1".
  CURRENT_HAS_NF=$(jq -r --arg key "$CURRENT_TICKET" \
    '.tickets[] | select(.key == $key) | if has("new_files") and .new_files != null then "1" else "0" end' "$MANIFEST")
  PRIOR_TICKETS=$(jq -r --arg key "$CURRENT_TICKET" \
    '.tickets[] | select(.key != $key and .status == "complete") | .key' "$MANIFEST")

  OVERLAP_COUNT=0
  for PRIOR in $PRIOR_TICKETS; do
    PRIOR_HAS_NF=$(jq -r --arg key "$PRIOR" \
      '.tickets[] | select(.key == $key) | if has("new_files") and .new_files != null then "1" else "0" end' "$MANIFEST")

    if [ "$CURRENT_HAS_NF" = "1" ] && [ "$PRIOR_HAS_NF" = "1" ]; then
      # ADR-017 amended path: compare NEW files only.
      PRIOR_NF=$(jq -r --arg key "$PRIOR" \
        '.tickets[] | select(.key == $key) | .new_files // [] | .[]' "$MANIFEST" | sort -u)
      OVERLAP=$(comm -12 <(printf '%s\n' "$CURRENT_NF") <(printf '%s\n' "$PRIOR_NF") | grep -v '^$' || true)
      DRIFT_KIND="files-already-newed-by"
    else
      # Legacy fallback: strict planned_files disjointness.
      PRIOR_PF=$(jq -r --arg key "$PRIOR" \
        '.tickets[] | select(.key == $key) | .planned_files[]' "$MANIFEST" | sort -u)
      OVERLAP=$(comm -12 <(printf '%s\n' "$CURRENT_PF") <(printf '%s\n' "$PRIOR_PF") | grep -v '^$' || true)
      DRIFT_KIND="files-already-claimed by"
    fi

    if [ -n "$OVERLAP" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] && echo "DRIFTED: ${DRIFT_KIND} ${PRIOR}: ${f}" >> "$OUT"
      done <<< "$OVERLAP"
      DRIFT_MESSAGES+=("Check 2: ${DRIFT_KIND} ${PRIOR}")
      DRIFTED=1
      OVERLAP_COUNT=$((OVERLAP_COUNT + 1))
    fi
  done
  if [ "$OVERLAP_COUNT" = "0" ]; then
    echo "No new_files / planned_files overlap between ${CURRENT_TICKET} and any prior \`complete\` ticket." >> "$OUT"
  fi
  echo "" >> "$OUT"
fi

# ---------------------------------------------------------------------------
# Check 3 — Wave-level disposition for current ticket is GO or
# REVIEW-PER-TICKET.
# ---------------------------------------------------------------------------
echo "## Check 3 — Wave-level disposition" >> "$OUT"
echo "" >> "$OUT"

if [ ! -f "$MANIFEST" ]; then
  echo "Skipped: wave-manifest.json not present." >> "$OUT"
  echo "" >> "$OUT"
else
  WCR=$(jq -r --arg key "$CURRENT_TICKET" \
    '.tickets[] | select(.key == $key) | .wave_cto_recommendation // "null"' "$MANIFEST")
  case "$WCR" in
    GO|REVIEW-PER-TICKET)
      echo "wave_cto_recommendation for ${CURRENT_TICKET} is \`${WCR}\`. Pass." >> "$OUT"
      ;;
    null)
      echo "wave_cto_recommendation for ${CURRENT_TICKET} is null (v1 wave OR w-cto did not populate). Pass (legacy path)." >> "$OUT"
      ;;
    *)
      echo "DRIFTED: ticket-deferred-or-blocked: wave_cto_recommendation is \`${WCR}\` (expected GO or REVIEW-PER-TICKET)." >> "$OUT"
      DRIFT_MESSAGES+=("Check 3: ticket-deferred-or-blocked (wave_cto_recommendation=${WCR})")
      DRIFTED=1
      ;;
  esac
  echo "" >> "$OUT"
fi

# ---------------------------------------------------------------------------
# Check 4 — Wave-manifest hasn't been structurally mutated since wave-start.
# Compare against the snapshot w-cto-consensus wrote (D3).
# Structural fields: tickets[].key, tickets[].depends_on, tickets[].planned_files.
# Per-ticket status changes are NOT structural (they happen during execution).
# ---------------------------------------------------------------------------
echo "## Check 4 — Wave-manifest structural integrity" >> "$OUT"
echo "" >> "$OUT"

if [ ! -f "$SNAPSHOT" ]; then
  echo "Skipped: wave-manifest-at-wave-start.json snapshot not present (w-cto-consensus may not have run yet, or v1 wave)." >> "$OUT"
  echo "" >> "$OUT"
elif [ ! -f "$MANIFEST" ]; then
  echo "Skipped: wave-manifest.json not present." >> "$OUT"
  echo "" >> "$OUT"
else
  NOW=$(jq -c '.tickets | sort_by(.key) | map({key: .key, depends_on: (.depends_on | sort), planned_files: (.planned_files | sort)})' "$MANIFEST")
  START=$(jq -c '.tickets | sort_by(.key) | map({key: .key, depends_on: (.depends_on | sort), planned_files: (.planned_files | sort)})' "$SNAPSHOT")
  if [ "$NOW" = "$START" ]; then
    echo "Wave-manifest structural shape (tickets/depends_on/planned_files) is unchanged since wave-start." >> "$OUT"
  else
    echo "DRIFTED: manifest-mutated: tickets/depends_on/planned_files differ from snapshot." >> "$OUT"
    echo "" >> "$OUT"
    echo "Snapshot:" >> "$OUT"
    echo '```json' >> "$OUT"
    echo "$START" | jq . >> "$OUT" 2>/dev/null || echo "$START" >> "$OUT"
    echo '```' >> "$OUT"
    echo "" >> "$OUT"
    echo "Current:" >> "$OUT"
    echo '```json' >> "$OUT"
    echo "$NOW" | jq . >> "$OUT" 2>/dev/null || echo "$NOW" >> "$OUT"
    echo '```' >> "$OUT"
    DRIFT_MESSAGES+=("Check 4: manifest-mutated")
    DRIFTED=1
  fi
  echo "" >> "$OUT"
fi

# ---------------------------------------------------------------------------
# Verdict line — LAST non-empty line per the verdict-line discipline.
# ---------------------------------------------------------------------------
echo "## Verdict" >> "$OUT"
echo "" >> "$OUT"
if [ "$DRIFTED" = "0" ]; then
  echo "VERDICT: CONSISTENT" >> "$OUT"
  echo "VERDICT: CONSISTENT"
else
  echo "VERDICT: DRIFTED" >> "$OUT"
  echo "VERDICT: DRIFTED"
fi

exit 0
