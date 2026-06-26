#!/usr/bin/env bash
# register-block-fable-dispatch.sh — OPERATOR-RUN one-shot: wires the Fable-dispatch ban live.
# (The orchestrator may not modify its own enforcement config — classifier-enforced; you run this.)
# Idempotent. Symlinks the hook into ~/.claude/hooks/ and registers it in ~/.claude/settings.json
# immediately after require-protocol.sh under the PreToolUse "Agent" matcher.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

SRC="$REPO_ROOT/core/hooks/block-fable-dispatch.sh"
DST="$HOME/.claude/hooks/block-fable-dispatch.sh"
# GUARD (SA-001): if ~/.claude/hooks is already a dir-symlink into this repo's core/hooks, then
# DST resolves THROUGH it back to SRC — `ln -sf SRC DST` would self-clobber SRC into a broken
# self-referential symlink. In that case the hook is already live (the dir is symlinked); skip.
if [ "$(cd "$(dirname "$DST")" 2>/dev/null && pwd -P)" = "$(cd "$(dirname "$SRC")" 2>/dev/null && pwd -P)" ]; then
  echo "~/.claude/hooks is already symlinked into core/hooks — hook is live via the dir-symlink; skipping per-file ln (SA-001 self-clobber guard)."
else
  ln -sf "$SRC" "$DST"
  echo "symlinked: $DST -> $SRC"
fi

python3 - <<'EOF'
import json, pathlib
p = pathlib.Path.home() / ".claude" / "settings.json"
s = json.loads(p.read_text())
pre = s["hooks"]["PreToolUse"]
entry = {"matcher": "Agent", "hooks": [{"type": "command",
         "command": "bash $HOME/.claude/hooks/block-fable-dispatch.sh", "timeout": 5}]}
if any("block-fable-dispatch" in h.get("command", "") for e in pre for h in e.get("hooks", [])):
    print("already registered — no change")
else:
    idx = next(i for i, e in enumerate(pre)
               if any("require-protocol" in h.get("command", "") for h in e.get("hooks", [])))
    pre.insert(idx + 1, entry)
    p.write_text(json.dumps(s, indent=2) + "\n")
    print(f"registered at PreToolUse index {idx + 1}")
for i, e in enumerate(pre):
    if e.get("matcher") == "Agent":
        print(" ", i, [h["command"] for h in e["hooks"]])
EOF

echo "Done. New sessions enforce immediately; verify in-session with any unpinned dispatch (should BLOCK)."
