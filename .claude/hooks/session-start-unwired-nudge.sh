#!/usr/bin/env bash
# SessionStart hook: nudge the operator when CC starts in an UN-wired repo (T-009).
#
# An "unwired repo" is a git repo whose `.claude/` substrate has not been installed via
# `setup.sh`. The chicken-and-egg framing (see `core/skills/onboard/SKILL.md` "Why this works
# in an un-wired repo"): skills live globally under `~/.claude/skills/` (symlinked from
# claude-infra's `core/skills/`), so `/onboard` is always available — but the operator may
# not know to run it. This hook emits a one-line advisory on session start when the cwd is
# an unwired git repo. Wired repos get nothing (silent pass-through).
#
# Security posture (T-009 spec): the hook reads cwd ONLY — `git rev-parse --show-toplevel`,
# `[ -d .claude/... ]` shape checks, and string comparison of paths. NO shell expansion of
# repo paths into commands; NO arbitrary input is ever exec'd. The hook ALSO self-excludes
# the claude-infra repo itself (which IS the substrate — nagging the substrate to onboard
# itself would be a nag-loop, and the substrate's own `.claude/` is its consumer-style
# layout, not what we are detecting).
#
# Exit semantics: always 0. Advisory-only; never blocks the session.

set -uo pipefail

# --- Resolve cwd's git root (if any). Outside a git repo, exit silently. ---
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$GIT_ROOT" ]; then
  exit 0
fi

# --- Self-exclusion: claude-infra is the substrate; do NOT nag it to onboard itself. ---
# Detection: the repo root contains `setup.sh` AND `core/agents/` (the infra repo's
# own canonical shape — a consumer repo has `.claude/agents/` but no top-level `setup.sh` /
# `core/` tree). This is a structural check, not a path-string match, so it survives the
# operator cloning the infra repo into an unusual path. Also covers worktrees of the infra
# repo (a worktree of claude-infra still carries the `core/` tree).
if [ -f "$GIT_ROOT/setup.sh" ] && [ -d "$GIT_ROOT/core/agents" ]; then
  # The "infra repo" / claude-infra root itself — silent pass-through; this IS the substrate.
  exit 0
fi

# --- Detect un-wired state ---
# A wired repo has `.claude/` populated with the substrate's symlinked dirs. We check for
# both `.claude/agents/` AND `.claude/rules/` since each may exist independently in partial
# setups; both being present is the strong signal that `setup.sh` has run.
if [ -d "$GIT_ROOT/.claude/agents" ] && [ -d "$GIT_ROOT/.claude/rules" ]; then
  # Wired — nothing to nudge about.
  exit 0
fi

# --- Emit the nudge (one-line advisory; never blocks) ---
# Skills live globally under `~/.claude/skills/`, so `/onboard` works from any session, even
# in an un-wired repo. Reference the onboard skill so the operator can dig in if they want
# the full chicken-and-egg explanation.
cat <<EOF
[claude-infra] This repo doesn't have the substrate wired in — \`.claude/\` is missing or incomplete.
[claude-infra] To wire it: run \`/onboard\` (skills are globally available, so /onboard works here
[claude-infra] without local setup). See: core/skills/onboard/SKILL.md.
EOF

exit 0
