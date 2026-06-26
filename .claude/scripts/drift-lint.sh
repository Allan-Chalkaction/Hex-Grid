#!/usr/bin/env bash
# drift-lint.sh — deterministic substrate-drift detection (ADR-080 D4).
#
# Grep-shaped, exit-coded checks for the drift classes that have bitten the
# substrate (the 2026-06-11 setup.sh self-link spray; stale registrations;
# dead-reference rot; stale stage-name references after the ADR-127 renumber).
# READ-ONLY. Each check is a function emitting PASS/WARN/FAIL lines + a per-check
# tally. The script exits 0 unless a FAIL-class check fails.
#
# FAIL classes (red): 1 self-referential/broken symlinks, 2 hook registration
#   (both directions), 5 rules-cited core/ paths that don't exist, 6 model-pin
#   allowlist, 7 doc-lifecycle root discipline, 8 live stale stage-name references
#   across the WHOLE tracked repo (SHR4-E2 / AC-018).
# WARN classes (report, don't fail): 3 stale delete-after markers, 4 dead track
#   arms lacking a dormant-by-design annotation.
#
# Usage: bash core/scripts/drift-lint.sh [--root DIR] [--quiet]
#   --root DIR  lint DIR instead of the repo root (used by the test harness against
#               a seeded-violation fixture tree).
#   --quiet     suppress PASS lines; show only WARN/FAIL + summary.
#
# Output ends with a machine-parseable line:
#   DRIFT-LINT: PASS (warnings=<n>)
#   DRIFT-LINT: FAIL (fails=<n> warnings=<n>)

set -uo pipefail

# --- Model-pin allowlist (the source of truth for check 6; ADR-080 D4 header constant) ---
# claude-fable-5 is the narrow Fable reversal authorized by ADR-088 D2 — currently the
# examiner seat only (judge reserved, not built). No other agent gains a Fable pin.
ALLOWED_MODELS="claude-opus-4-8[1m] sonnet haiku claude-fable-5"

# --- args ---
ROOT=""
QUIET=false
for a in "$@"; do
  case "$a" in
    --quiet) QUIET=true ;;
    --root) ROOT="__NEXT__" ;;
    *)
      if [ "$ROOT" = "__NEXT__" ]; then ROOT="$a"; else
        echo "drift-lint: unknown arg '$a'" >&2; exit 2
      fi
      ;;
  esac
done
if [ "$ROOT" = "__NEXT__" ] || [ -z "$ROOT" ]; then
  if [ -z "$ROOT" ] || [ "$ROOT" = "__NEXT__" ]; then
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
fi
ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || { echo "drift-lint: cannot cd to root '$ROOT'" >&2; exit 2; }

FAILS=0
WARNS=0
fail() { FAILS=$((FAILS + 1)); echo "  FAIL: $*"; }
warn() { WARNS=$((WARNS + 1)); echo "  WARN: $*"; }
ok()   { [ "$QUIET" = true ] || echo "  PASS: $*"; }
hdr()  { echo ""; echo "--- $* ---"; }

# Settings files that may register hooks (mirror infra-doctor's list).
SETTINGS_FILES=(
  "$ROOT/core/config/global/settings.json"
  "$ROOT/.claude/settings.json"
  "$ROOT/.claude/settings.local.json"
)
# Hooks intentionally not registered in settings (opt-in / indirectly dispatched).
# Opt-in: graphiti read/capture. Indirect: sync-artifacts-post-agent.sh is dispatched
# by post-tool-use-workflow.sh.
HOOK_REG_ALLOWLIST="session-start-graphiti-read.sh session-end-graphiti-capture.sh sync-artifacts-post-agent.sh post-commit-graphiti-adr.sh"

# ============================================================================
# Check 1 — Self-referential / broken symlinks under core/ and docs/.
# (The 2026-06-11 setup.sh self-link incident class: 58 junk links.)
# ============================================================================
check_symlinks() {
  hdr "1. Self-referential / broken symlinks (core/, docs/)"
  local n_bad=0 d
  # Canonical form of ROOT for the inside-the-repo comparison: `readlink -f`
  # canonicalizes symlinked path prefixes (e.g. macOS /var -> /private/var), so a
  # link target resolved with `readlink -f` must be compared against the
  # canonicalized root, not the logical `pwd` root.
  local root_canon
  root_canon="$(readlink -f "$ROOT" 2>/dev/null || echo "$ROOT")"
  for d in core docs; do
    [ -d "$ROOT/$d" ] || continue
    while IFS= read -r link; do
      [ -z "$link" ] && continue
      local target resolved
      target="$(readlink "$link" 2>/dev/null)"
      # Broken: the link does not resolve to an existing path.
      if [ ! -e "$link" ]; then
        n_bad=$((n_bad + 1))
        fail "broken symlink: ${link#$ROOT/} -> ${target:-?} (target missing)"
        continue
      fi
      # Self-referential: resolves back into the repo itself (a managed infra
      # symlink should point at an EXTERNAL infra tree, never inside this repo).
      resolved="$(cd "$(dirname "$link")" 2>/dev/null && readlink -f "$link" 2>/dev/null || true)"
      case "$resolved" in
        "$root_canon"/*|"$ROOT"/*)
          n_bad=$((n_bad + 1))
          fail "self-referential symlink: ${link#$ROOT/} -> resolves inside the repo (${resolved#$root_canon/})"
          ;;
      esac
    done < <(find "$ROOT/$d" -type l 2>/dev/null)
  done
  [ "$n_bad" -eq 0 ] && ok "no self-referential or broken symlinks under core/ or docs/"
}

# ============================================================================
# Check 2 — Hook registration, both directions.
#   (a) every core/hooks/*.sh is registered (settings file OR allowlisted as
#       opt-in/indirect).
#   (b) every settings-registered .claude/hooks/<name> has a backing core/hooks file.
# ============================================================================
check_hook_registration() {
  hdr "2. Hook registration (both directions)"
  local n_bad=0 h base
  # (a) unregistered hooks
  for h in "$ROOT"/core/hooks/*.sh; do
    [ -f "$h" ] || continue
    base="$(basename "$h")"
    local registered=false f
    for f in "${SETTINGS_FILES[@]}"; do
      [ -f "$f" ] || continue
      grep -q "$base" "$f" 2>/dev/null && { registered=true; break; }
    done
    if [ "$registered" = false ]; then
      case " $HOOK_REG_ALLOWLIST " in
        *" $base "*) ;;  # opt-in / indirect — allowed
        *)
          n_bad=$((n_bad + 1))
          fail "hook not registered in any settings file and not allowlisted: $base"
          ;;
      esac
    fi
  done
  # (b) dead registrations — a settings file registers .claude/hooks/<name> with no backing core/hooks file.
  local f ref rb
  for f in "${SETTINGS_FILES[@]}"; do
    [ -f "$f" ] || continue
    while IFS= read -r ref; do
      rb="${ref##*/}"
      [ -z "$rb" ] && continue
      case "$rb" in *.sh) ;; *) continue ;; esac   # only lint shell hooks (js notifiers handled elsewhere)
      if [ ! -e "$ROOT/core/hooks/$rb" ]; then
        n_bad=$((n_bad + 1))
        fail "${f#$ROOT/} registers '.claude/hooks/$rb' but core/hooks/$rb does not exist (dead reference)"
      fi
    done < <(grep -oE '\.claude/hooks/[A-Za-z0-9._-]+\.sh' "$f" 2>/dev/null | sort -u)
  done
  [ "$n_bad" -eq 0 ] && ok "hook registration consistent (both directions)"
}

# ============================================================================
# Check 5 — Reference resolution: backtick core/ paths cited in core/rules/*.md
# that no longer exist. (Run before 3/4 so FAIL classes group; numbering follows
# ADR-080 D4.)
# ============================================================================
check_rule_references() {
  hdr "5. Reference resolution (core/rules cited core/ paths exist)"
  local n_bad=0 rf
  for rf in "$ROOT"/core/rules/*.md; do
    [ -f "$rf" ] || continue
    # Backtick-wrapped paths beginning with core/ (strip a trailing :NNN line ref).
    while IFS= read -r cited; do
      [ -z "$cited" ] && continue
      # strip trailing :line-number, anchors, and trailing punctuation
      local clean="${cited%%:*}"
      clean="${clean%%#*}"
      # glob paths (core/agents/*.md) are patterns, not single files — skip them.
      case "$clean" in
        *"*"*) continue ;;
      esac
      if [ ! -e "$ROOT/$clean" ]; then
        n_bad=$((n_bad + 1))
        fail "${rf#$ROOT/} cites \`$clean\` which does not exist"
      fi
    done < <(grep -oE '`core/[A-Za-z0-9._/-]+`' "$rf" 2>/dev/null | tr -d '`' | sort -u)
  done
  [ "$n_bad" -eq 0 ] && ok "all core/ paths cited in core/rules/*.md resolve"
}

# ============================================================================
# Check 6 — Model-pin allowlist: every core/agents/*.md model: value ∈ allowed set.
# ============================================================================
check_model_pins() {
  hdr "6. Model-pin allowlist (core/agents/*.md)"
  local n_bad=0 af val
  for af in "$ROOT"/core/agents/*.md; do
    [ -f "$af" ] || continue
    val="$(grep -m1 -E '^model:' "$af" 2>/dev/null | sed -E 's/^model:[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$val" ] && continue   # no pin = inherits main conversation; not a violation
    case " $ALLOWED_MODELS " in
      *" $val "*) ;;
      *)
        n_bad=$((n_bad + 1))
        fail "$(basename "$af"): model '$val' not in allowlist ($ALLOWED_MODELS)"
        ;;
    esac
  done
  [ "$n_bad" -eq 0 ] && ok "all agent model pins in allowlist ($ALLOWED_MODELS)"
}

# ============================================================================
# Check 3 — Stale delete-after markers (WARN). A marker line whose file still
# exists is a candidate-past milestone worth a human look.
# ============================================================================
check_stale_markers() {
  hdr "3. Stale delete-after markers (WARN)"
  local n=0 f
  # marker phrases that imply a planned removal
  local pat='delete after|pending the path cuts|retired in T-[0-9]|delete this file|remove after'
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    # Skip this lint script + test harnesses: they legitimately contain the marker
    # pattern literals / seeded-fixture content, not real stale markers.
    case "$hit" in
      core/scripts/drift-lint.sh:*) continue ;;
      core/scripts/test-*.sh:*)     continue ;;
    esac
    n=$((n + 1))
    warn "stale-marker candidate: $hit"
  done < <(grep -rniE "$pat" "$ROOT/core/rules" "$ROOT/core/hooks" "$ROOT/core/scripts" 2>/dev/null \
            | sed "s#$ROOT/##" | head -40)
  [ "$n" -eq 0 ] && ok "no stale delete-after markers"
}

# ============================================================================
# Check 4 — Dead track arms (WARN). `case` arms in hooks matching retired track
# strings that lack a dormant-by-design annotation on the line above.
# ============================================================================
check_dead_track_arms() {
  hdr "4. Dead track arms without dormant-by-design annotation (WARN)"
  local n=0 h
  local dead_tracks='pipeline|adhoc'
  for h in "$ROOT"/core/hooks/*.sh; do
    [ -f "$h" ] || continue
    # find `  <track>)` case-arm lines
    while IFS= read -r ln; do
      [ -z "$ln" ] && continue
      local lineno="${ln%%:*}"
      # A dormant-by-design annotation may sit on the line ABOVE the arm or as
      # the FIRST line inside the arm body (line below) — accept either.
      local prev next
      prev="$(sed -n "$((lineno - 1))p" "$h" 2>/dev/null)"
      next="$(sed -n "$((lineno + 1))p" "$h" 2>/dev/null)"
      case "$prev$next" in
        *dormant-by-design*) continue ;;
      esac
      n=$((n + 1))
      warn "$(basename "$h"):$lineno — track arm '$(echo "$ln" | sed "s/^[0-9]*: *//")' lacks a dormant-by-design annotation"
    done < <(grep -nE "^[[:space:]]+($dead_tracks)\)" "$h" 2>/dev/null)
  done
  [ "$n" -eq 0 ] && ok "all dead track arms carry a dormant-by-design annotation (or none present)"
}

# ============================================================================
# Check 7 — Doc-lifecycle root discipline (ADR-087 D2.1). Work-shaped .md files
# must live in a step folder, backlog/, or parked/ — minting a new top-level docs/
# location requires an ADR. FAIL on a work-shaped file at an unexpected docs/ top-level
# location. Cheap + non-flaky: only inspects the immediate docs/<dir>/ level (and
# bare docs/*.md), never recurses. step-1-ideas is the canonical inbox (ADR-089 renamed
# it back from step-1-backlog); only deferrals/step-0-backlog/handbook/investigations
# remain GRANDFATHERED to a WARN until the operator rehomes them.
# ============================================================================
check_doc_lifecycle_root() {
  hdr "7. Doc-lifecycle root discipline (ADR-087 D2.1 / ADR-089 D2)"
  local docs="$ROOT/docs"
  [ -d "$docs" ] || { ok "no docs/ tree to lint"; return; }
  # Allowed top-level docs/ homes (lifecycle step folders + the two shelves + reference homes).
  # backlog/ + parked/ are the two operator shelves (ADR-089 D2); chores/ is the ADR-090 execution lane.
  # Person-folders match `[a-z]+\.[a-z]+`; feature-runbook homes (graphiti) + conventions are reference.
  # step-[1-6]: the pipeline renumber (ADR-127) gave the queue a number (step-4-queue) and shifted the
  # downstream stages (step-5-pipeline, step-6-done) — the bare top-level `queue` home is retired (it now
  # matches step-[1-6] as step-4-queue).
  # Recognized homes (ADR-133): shelves (backlog/parked/abandoned/chores), reference (decisions/conventions/
  # playbooks), feature-runbooks (graphiti/launch), person folders ([a-z]+.[a-z]+). abandoned=4th shelf
  # (sibling of parked); playbooks=portable-methodology reference; launch=/launch feature-runbook (sibling of graphiti).
  local allow_re='^(step-[1-6]-[a-z-]+|backlog|parked|abandoned|chores|decisions|conventions|playbooks|graphiti|launch|[a-z]+\.[a-z]+)$'
  # Legacy dirs grandfathered to WARN until the operator migrates/rehomes them (they predate ADR-087):
  #   deferrals — merged by migrate-doc-lifecycle.sh into step-1-ideas (the inbox).
  #   step-0-backlog + handbook + investigations — pre-ADR-087 top-level homes; rehome on /sweep, not a FAIL.
  local legacy_re='^(deferrals|step-0-backlog|handbook|investigations)$'
  # Bare docs/*.md files predating ADR-087 (operator-known reference) — WARN, don't FAIL.
  local legacy_root_md_re='^(build-principles)\.md$'
  local n_bad=0 d base
  # (a) bare docs/*.md — only README.md / INDEX.md / BUILD-STATUS.md are allowed at the docs/ root; legacy ones WARN.
  # BUILD-STATUS.md is a generated dashboard (ADR-109 W3, paired ADR) — RENDERED by docs-index.py like INDEX.md.
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    base="$(basename "$f")"
    case "$base" in
      README.md|INDEX.md|BUILD-STATUS.md) ;;
      *)
        if printf '%s' "$base" | grep -qE "$legacy_root_md_re"; then
          warn "legacy bare doc docs/$base still at root — rehome under a step folder or a reference home (ADR-087); grandfathered until then"
        else
          n_bad=$((n_bad + 1)); fail "work-shaped file at docs/ root: docs/$base (move into a step folder or parked/)"
        fi ;;
    esac
  done < <(find "$docs" -maxdepth 1 -type f -name '*.md' 2>/dev/null)
  # (b) docs/<dir>/ that holds work-shaped .md but isn't an allowed home.
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    base="$(basename "$d")"
    # allowed home → fine
    if printf '%s' "$base" | grep -qE "$allow_re"; then continue; fi
    # does it contain any .md (work-shaped)? empty/non-md dirs are harmless.
    if find "$d" -maxdepth 2 -type f -name '*.md' 2>/dev/null | grep -q .; then
      if printf '%s' "$base" | grep -qE "$legacy_re"; then
        warn "legacy lifecycle dir docs/$base/ still present — migrate via migrate-doc-lifecycle.sh (ADR-087) + the ADR-089 rename (git mv docs/step-1-backlog docs/step-1-ideas); grandfathered until then"
      else
        n_bad=$((n_bad + 1))
        fail "work-shaped .md under unexpected top-level docs/$base/ — mint a step folder or an ADR (ADR-087 D2.1)"
      fi
    fi
  done < <(find "$docs" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
  [ "$n_bad" -eq 0 ] && ok "all work-shaped docs live in a step folder / parked/ / reference home (ADR-087 D2.1)"
}

# ============================================================================
# Check 8 — Stale stage-name references in LIVE-CONTRACT surfaces (SHR4-E2 / AC-018).
# The ADR-127 renumber retired the pre-rename stage names `step-4-pipeline` and
# `step-5-done` (they became step-5-pipeline / step-6-done; queue took step-4). A
# LIVE reference to an old name is stale drift that, pre-E2, shipped green because the
# renumber verification grep was scoped to core/ + CLAUDE.md and never scanned the
# whole tracked repo (so a root-level stale reference — e.g. setup.sh — slipped
# through). This check scans the whole tracked tree, with two calibrations (SHR4-E2,
# tuned against the live find that the naive whole-repo grep surfaced):
#
#  (1) PATH-QUALIFIED PATTERN. It matches the old name USED AS A LIVE PATH
#      (`docs/step-4-pipeline` / `docs/step-5-done`) — a folder a script writes to or
#      a doc presents as current. This is the real bug class (the round-4 setup.sh
#      mkdir miss; a convention doc presenting a retired path as current). It does NOT
#      match a bare-token descriptive annotation (`# … (was step-4-pipeline)` in
#      setup.sh) — a past-tense rename note is not live usage.
#  (2) HISTORY/ARCHIVAL EXCLUDES (load-bearing). The append-only history + archival
#      doc trees legitimately carry old PATHS (a finding/spec/ADR/run-folder citing
#      where something WAS) and must NOT count as live usage — rewriting history would
#      corrupt the record. Excluded: docs/decisions/ (ADRs), docs/step-1-ideas/ (inbox
#      history), docs/step-2-planning/ (jam history), docs/step-3-specs/ (planning
#      history), docs/step-5-pipeline/ + docs/step-6-done/ (run-folder artifacts),
#      docs/playbooks/ + docs/<person>/ (historical notes), and the generated
#      docs/INDEX.md / docs/BUILD-STATUS.md.
#
# What REMAINS in scope is the live-contract surface — core/**, setup.sh,
# switch-infra.sh, CLAUDE.md, docs/conventions/**, runbooks — where a stale stage
# PATH is an actual bug. A match there is LIVE stale usage and FAILs (red).
# ============================================================================
check_stale_stage_names() {
  hdr "8. Stale stage-name references in live-contract surfaces (SHR4-E2 / AC-018)"
  local n_bad=0
  # TOOLING-LITERAL skip (mirrors Check 3): this lint script + the renumber migration
  # tooling legitimately contain the old names as STRING LITERALS (they perform/test
  # the rename, or — here — name the pattern). Not live drift; same category as
  # Check 3's drift-lint.sh / test-*.sh self-match skip, NOT an exclude-set widening.
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    case "$hit" in
      core/scripts/drift-lint.sh:*) continue ;;             # this check's own pattern literals
      core/skills/doctor/SKILL.md:*) continue ;;            # /doctor docs naming this check's pattern
      core/scripts/queue-migrate-preflight.py:*) continue ;; # the renumber migration tool (old↔new literals)
      core/scripts/test-queue-migration.sh:*) continue ;;    # the migration test harness (seeds old names)
    esac
    n_bad=$((n_bad + 1))
    fail "stale stage-name PATH reference (live): $hit"
  done < <(cd "$ROOT" 2>/dev/null && git grep -nE 'docs/step-4-pipeline|docs/step-5-done' -- \
            ':!docs/decisions/' ':!docs/step-1-ideas/' ':!docs/step-2-planning/' \
            ':!docs/step-3-specs/' ':!docs/step-5-pipeline/' ':!docs/step-6-done/' \
            ':!docs/playbooks/' ':!docs/jane.doe/' ':!docs/INDEX.md' \
            ':!docs/BUILD-STATUS.md' 2>/dev/null)
  [ "$n_bad" -eq 0 ] && ok "no live stale stage-name PATH references (docs/step-4-pipeline / docs/step-5-done) in live-contract surfaces"
}

# ============================================================================
echo "=== drift-lint (ADR-080 D4) — root: ${ROOT} ==="
check_symlinks
check_hook_registration
check_rule_references
check_model_pins
check_stale_markers
check_dead_track_arms
check_doc_lifecycle_root
check_stale_stage_names

echo ""
echo "============================================================"
if [ "$FAILS" -eq 0 ]; then
  echo "DRIFT-LINT: PASS (warnings=${WARNS})"
  exit 0
else
  echo "DRIFT-LINT: FAIL (fails=${FAILS} warnings=${WARNS})"
  exit 1
fi
