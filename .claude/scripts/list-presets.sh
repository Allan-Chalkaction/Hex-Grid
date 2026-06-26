#!/usr/bin/env bash
# list-presets.sh — list the available v2 Workflow engine presets.
#
# For each core/scripts/workflows/*.js file (EXCLUDING the legacy
# *-preset.js spike artifacts), extract the preset's `meta.name` and the
# first sentence of its `meta.description` and print one line per preset:
#
#   <name>  -  <first sentence of description>
#
# Usage:
#   core/scripts/list-presets.sh
#   core/scripts/list-presets.sh --help
#
# Exits 0 if no presets are found (tolerant). Must be run from the repo
# root (the directory containing core/scripts/workflows/).

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: list-presets.sh [--help]

Lists the available v2 Workflow engine presets discovered under
core/scripts/workflows/*.js (excluding legacy *-preset.js spike artifacts).

For each preset, prints:
  <meta.name>  -  <first sentence of meta.description>

Run from the repo root. Exits 0 with no output if no presets are found.

Options:
  --help    Show this help and exit.
EOF
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    echo "list-presets.sh: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac

WORKFLOWS_DIR="core/scripts/workflows"

if [ ! -d "$WORKFLOWS_DIR" ]; then
  echo "list-presets.sh: no preset directory at $WORKFLOWS_DIR (run from repo root)" >&2
  exit 0
fi

# Collect candidate files, excluding legacy *-preset.js spike artifacts.
shopt -s nullglob
candidates=()
for f in "$WORKFLOWS_DIR"/*.js; do
  case "$(basename "$f")" in
    *-preset.js) continue ;;
  esac
  candidates+=("$f")
done
shopt -u nullglob

if [ "${#candidates[@]}" -eq 0 ]; then
  # Tolerant: no presets found is not an error.
  exit 0
fi

# Extract name + first sentence of description from each file.
# meta exports are single-line `name: 'foo',` and `description: 'one sentence. more.',`
# We rely on that shape (verified by exploration) — a robust JS parser would
# be overkill for a small utility script.
for f in "${candidates[@]}"; do
  name=$(grep -m 1 -E "^[[:space:]]*name:[[:space:]]*'" "$f" \
         | sed -E "s/^[[:space:]]*name:[[:space:]]*'([^']*)'.*/\1/")
  desc=$(grep -m 1 -E "^[[:space:]]*description:[[:space:]]*'" "$f" \
         | sed -E "s/^[[:space:]]*description:[[:space:]]*'(.*)'[[:space:]]*,?[[:space:]]*$/\1/")

  if [ -z "$name" ]; then
    # Skip files without a recognizable meta.name — they aren't presets.
    continue
  fi

  # First sentence: everything up to (and including) the first `. ` (period+space)
  # or, failing that, the entire description.
  if [[ "$desc" == *". "* ]]; then
    first_sentence="${desc%%. *}."
  else
    first_sentence="$desc"
  fi

  printf '%s  -  %s\n' "$name" "$first_sentence"
done
