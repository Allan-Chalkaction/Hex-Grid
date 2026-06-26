#!/usr/bin/env bash
# test-setup-prune.sh — verifies setup.sh --refresh prunes stale infra symlinks
# precisely: orphaned infra-targeted links are removed, while local override files
# and unrelated (non-infra) symlinks are preserved, and the current source relinks.
# Self-contained: runs the real setup.sh against a throwaway temp consumer.
set -uo pipefail
INFRA_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SETUP="$INFRA_DIR/setup.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  PASS: $1"; }
no(){ FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CONSUMER="$TMP/consumer"
mkdir -p "$CONSUMER/.claude/skills" "$CONSUMER/.claude/commands"

# 1. Stale infra-targeted orphan symlink (target contains /core/ → must be PRUNED).
ln -s "/nonexistent/infra/core/skills/ghost-skill" "$CONSUMER/.claude/skills/ghost-skill"
# 2. Local override file (real file → must be PRESERVED).
echo "local override" > "$CONSUMER/.claude/skills/my-local-skill.md"
# 3. Unrelated non-infra symlink (target has no /core/ or /stacks/, and resolves so it
#    is not "broken" → must be PRESERVED).
ln -s "$TMP" "$CONSUMER/.claude/commands/unrelated-dir"
# 4. Stale STACK-targeted orphan symlink (target contains /stacks/ → must be PRUNED;
#    exercises the second arm of the case glob).
mkdir -p "$CONSUMER/.claude/agents"
ln -s "/nonexistent/infra/stacks/web/agents/ghost-stack-agent" "$CONSUMER/.claude/agents/ghost-stack-agent"

echo "=== running real setup.sh --refresh against temp consumer ==="
bash "$SETUP" "$CONSUMER" --refresh >"$TMP/out.log" 2>&1
echo "  (setup.sh exit: $?)"

# Assertions
[ ! -e "$CONSUMER/.claude/skills/ghost-skill" ] && ok "stale infra orphan symlink pruned" || no "stale infra orphan symlink NOT pruned"
[ -f "$CONSUMER/.claude/skills/my-local-skill.md" ] && [ ! -L "$CONSUMER/.claude/skills/my-local-skill.md" ] && ok "local override file preserved" || no "local override file lost"
[ -L "$CONSUMER/.claude/commands/unrelated-dir" ] && ok "unrelated non-infra symlink preserved" || no "unrelated non-infra symlink lost"
[ ! -e "$CONSUMER/.claude/agents/ghost-stack-agent" ] && ok "stale /stacks/-targeted orphan pruned (2nd case arm)" || no "stale /stacks/-targeted orphan NOT pruned"
# Current source relinked: a known v2 skill is a symlink whose target points into core/.
# (We assert the link + target, NOT physical resolution: macOS mktemp lives under
# /var -> /private/var, which breaks lexical relative-symlink resolution in temp dirs
# only — real consumers are not under that indirection. The prune behavior under test
# is fully covered by the assertions above.)
LNK="$CONSUMER/.claude/skills/nimble"
{ [ -L "$LNK" ] && case "$(readlink "$LNK")" in */core/skills/nimble) true;; *) false;; esac; } && ok "current source relinked (skills/nimble -> core)" || no "current source not relinked"
grep -q "Pruned:" "$TMP/out.log" && ok "prune step ran (logged)" || no "prune step did not log"

echo "=== test-setup-prune: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
