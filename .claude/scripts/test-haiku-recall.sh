#!/usr/bin/env bash
# test-haiku-recall.sh — hermetic matched-recall GATE for a future haiku swap.
#
# This is the GATE, not the swap: W1 ships ONLY this harness and adopts NO haiku.
# The sonnet floor (block-fable-dispatch.sh, ADR-099) stands regardless of this
# harness's outcome. A future wave that wants to re-pin an agent to haiku must
# first show measured recall parity here; this harness is the blocker that ADR-099
# names as the haiku follow-on gate.
#
# Method: a hermetic known-answer corpus. We build a fixed find/grep/list/extract
# corpus with KNOWN answers and assert that "haiku recall" reproduces the same
# answers as a sonnet/opus BASELINE on that corpus. The corpus answers are
# deterministic file operations (the substrate-relevant recall tasks: find an
# agent's frontmatter pin, list agent types, grep a hook's exit contract, extract
# an ADR number) — so the test is reproducible anywhere, with no model call and no
# network. A real future swap would replace the baseline/candidate transcripts
# with model outputs; here both are computed deterministically so the harness
# is green on its own corpus and serves as the structural gate.
#
# Hermetic: fixtures live in a mktemp project dir; HOME is overridden so the real
# ~/.claude cannot leak into resolution. Pattern mirrors
# core/scripts/test-block-fable-dispatch.sh and test-require-protocol-v2.sh.
#
# Exit 0: all recall tasks match the baseline (green on its corpus).
# Exit 1: at least one recall mismatch (the gate would block a haiku swap).
#
# Governing decision: ADR-099 (fable dispatch ban + sonnet floor; this harness is
# the W1 gate for the deferred haiku adoption).

set -u

total=0
failures=0

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Hermetic isolation: override HOME so real ~/.claude cannot leak; anchor the
# project dir to the fixture tree.
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/proj/.claude/agents"
export CLAUDE_PROJECT_DIR="$TMP/proj"
CORPUS="$TMP/proj"

# --- Known-answer corpus fixtures ---------------------------------------------
cat > "$CORPUS/.claude/agents/implementer.md" <<'EOF'
---
name: implementer
model: claude-opus-4-8[1m]
---
The single full-stack implementer.
EOF

cat > "$CORPUS/.claude/agents/docs-writer.md" <<'EOF'
---
name: docs-writer
model: haiku
---
Documentation author.
EOF

cat > "$CORPUS/.claude/agents/examiner.md" <<'EOF'
---
name: examiner
model: claude-opus-4-8[1m]
---
Review verb.
EOF

mkdir -p "$CORPUS/notes"
cat > "$CORPUS/notes/decision.md" <<'EOF'
# ADR-099 — fable dispatch ban + sonnet floor
The hook fails closed: exit 2 on any parse failure.
Allowlist is type-keyed {examiner}.
EOF

# --- Recall tasks: each computes an answer two ways (baseline vs candidate). -----
# In a real swap, candidate := haiku model output, baseline := sonnet/opus output.
# Here both are deterministic file operations so the harness is reproducible; the
# parity assertion (candidate == baseline == expected) is the structural gate.

# baseline_extract / candidate_extract: the two "recall passes". They are the SAME
# deterministic extraction in this hermetic harness (no model call); a future swap
# wires the candidate to a haiku transcript and the baseline to a sonnet/opus one.
baseline_extract() { eval "$1"; }
candidate_extract() { eval "$1"; }

assert_recall() {
  local desc="$1" extract_cmd="$2" expected="$3"
  total=$((total+1))
  local baseline candidate
  baseline=$(baseline_extract "$extract_cmd")
  candidate=$(candidate_extract "$extract_cmd")
  if [ "$baseline" != "$expected" ]; then
    echo "FAIL: $desc — baseline '$baseline' != known answer '$expected'"
    failures=$((failures+1)); return
  fi
  if [ "$candidate" != "$baseline" ]; then
    echo "FAIL: $desc — haiku recall '$candidate' != baseline '$baseline' (parity gate)"
    failures=$((failures+1)); return
  fi
  echo "PASS: $desc (recall='$candidate')"
}

# Task 1 — EXTRACT: find the implementer's frontmatter model pin.
assert_recall "extract implementer model pin" \
  "grep -m1 -E '^[[:space:]]*model:' \"\$CLAUDE_PROJECT_DIR/.claude/agents/implementer.md\" | sed -E 's/^[[:space:]]*model:[[:space:]]*//'" \
  "claude-opus-4-8[1m]"

# Task 2 — LIST: count the agent files in the corpus.
assert_recall "list agent file count" \
  "ls \"\$CLAUDE_PROJECT_DIR/.claude/agents/\"*.md | wc -l | tr -d '[:space:]'" \
  "3"

# Task 3 — FIND: which agent is pinned to haiku (basename only).
assert_recall "find the haiku-pinned agent" \
  "grep -lE '^[[:space:]]*model:[[:space:]]*haiku' \"\$CLAUDE_PROJECT_DIR/.claude/agents/\"*.md | xargs -n1 basename | sed 's/\\.md\$//'" \
  "docs-writer"

# Task 4 — GREP+EXTRACT: pull the ADR number from the decision note.
assert_recall "extract ADR number from decision note" \
  "grep -oE 'ADR-[0-9]+' \"\$CLAUDE_PROJECT_DIR/notes/decision.md\" | head -1" \
  "ADR-099"

# Task 5 — GREP: extract the fail-closed exit contract line value.
assert_recall "extract fail-closed exit code" \
  "grep -oE 'exit [0-9]+' \"\$CLAUDE_PROJECT_DIR/notes/decision.md\" | head -1 | grep -oE '[0-9]+'" \
  "2"

echo "---"
echo "test-haiku-recall: $((total-failures))/$total passed"
[ "$failures" -eq 0 ] || exit 1
exit 0
