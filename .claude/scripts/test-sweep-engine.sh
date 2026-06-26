#!/usr/bin/env bash
# Synthetic test for sweep.js — /sweep on the Workflow engine (SHR3-T7, ADR-039/ADR-087).
#
# Asserts:
#   (a) DETERMINISM + ONE-LLM-SEAM — cluster + vitality run with NO LLM; converge is
#       the SOLE agent(/LLM seam. Proven two ways: a grep that agent( appears exactly
#       once in executable code, AND a runnable end-to-end pass (clusters=[] -> the
#       converge guard skips -> the engine produces deterministic move/commit intents
#       with the agent stub NEVER called).
#   (b) DROP -> visible dropped/ via git mv, NO git rm (location-is-status, AC-020).
#   (c) SELF-COMMIT stages only touched paths (explicit addPaths, never -A), local,
#       no push (AC-021 — the security boundary).
#   (d) ROUTER moves a seeded findings/README OUT of the ideas inbox (AC-022).
#   Plus: cluster-floor determinism via the reused Wave C sweep-cluster.py.
#
# Exit 0: all pass. Exit 1: any fail.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
SWEEP="$REPO_ROOT/core/scripts/workflows/sweep.js"
SKILL="$REPO_ROOT/core/skills/sweep/SKILL.md"
CLUSTER_PY="$REPO_ROOT/core/scripts/sweep-cluster.py"

PASS=0; FAIL=0
ok() { echo "  PASS: $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL: $1 — ${2:-}"; FAIL=$((FAIL+1)); }

echo "=== test-sweep-engine.sh ==="
echo "SWEEP: $SWEEP"
echo

[ -f "$SWEEP" ] || { echo "ERROR: sweep.js not found"; exit 2; }

# --- 0. export const meta + JS parses ---
grep -q 'export const meta' "$SWEEP" && ok "sweep.js exports const meta (visible in /workflows; AC-019)" \
  || ko "meta export" "no 'export const meta'"
if node --check "$SWEEP" 2>/dev/null; then ok "sweep.js parses (node --check)"; else ko "js parse" "node --check failed"; fi

# --- (a) ONE-LLM-SEAM (grep): exactly ONE executable agent( call ------------
# Count agent( occurrences in NON-comment lines (strip // comments and the meta
# description string). The deterministic cluster + vitality steps must contain none.
AGENT_EXEC=$(grep -nE 'agent\(' "$SWEEP" | grep -vE '^[0-9]+:[[:space:]]*//' | grep -vE "description:" | grep -cE 'agent\(' || true)
if [ "$AGENT_EXEC" = "1" ]; then
  ok "converge is the SOLE LLM seam — exactly 1 executable agent( call (AC-019)"
else
  ko "one-llm-seam" "expected exactly 1 executable agent( call, found $AGENT_EXEC"
fi

# --- (b)/(c) drop path git-rm-clean + sweep.js push/origin/-A clean (grep) ---
if grep -nE 'git rm' "$SWEEP" >/dev/null 2>&1; then ko "drop path git-rm" "git rm present in sweep.js"; else ok "sweep.js drop path is git-rm-clean (AC-020)"; fi
if grep -nE 'git rm' "$SKILL" >/dev/null 2>&1; then
  # tolerate non-drop-path git rm in the skill (the §2b pool-dedup route), but the
  # drop VERDICT row must be git-rm-free. Assert the drop verdict line is clean.
  DROP_LINE=$(grep -nE '^\| \*\*drop\*\*' "$SKILL" || true)
  if printf '%s' "$DROP_LINE" | grep -qE 'git rm'; then ko "skill drop verdict git-rm" "drop row still uses git rm"; else ok "skill drop verdict is git-rm-clean (uses git mv to dropped/; AC-020)"; fi
else
  ok "skill is git-rm-clean"
fi
if grep -nE 'git push|origin' "$SWEEP" >/dev/null 2>&1; then ko "self-commit push" "git push/origin present in sweep.js"; else ok "sweep.js self-commit is push/origin-clean (AC-021)"; fi
if grep -nE 'git add -A' "$SWEEP" >/dev/null 2>&1; then ko "git add -A" "git add -A present in sweep.js"; else ok "sweep.js never uses git add -A (AC-021)"; fi

# --- RUNNABLE end-to-end: the deterministic path with a STUBBED agent ---------
# sweep.js ends in a top-level `return payload` (legal only inside the Workflow tool's
# function wrapper, not a bare ESM import). So we exercise the REAL engine body by
# stripping the `export const meta` block and running the remainder inside an async
# Function wrapper that captures the returned payload. clusters=[] makes the converge
# guard skip, and the agent stub THROWS if ever called — proving the deterministic
# path needs no LLM.
EXERCISE=$(SWEEP_PATH="$SWEEP" node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const src = readFileSync(process.env.SWEEP_PATH, "utf8");
  // Strip the `export const meta = {...}` block (illegal inside a function body) — the
  // engine body after it is what we exercise. meta ends at the first top-level "}\n".
  const afterMeta = src.replace(/^export const meta = \{[\s\S]*?\n\}\n/, "");
  let agentCalled = false;
  const agent = async () => { agentCalled = true; throw new Error("agent called on deterministic path"); };
  const parallel = async (thunks) => Promise.all(thunks.map(t => t()));
  const phase = () => {};
  const log = () => {};
  const args = {
    runDir: "docs/step-5-pipeline/X/run", repoRoot: ".", inbox: "docs/step-1-ideas",
    clusters: [], drops: ["bad-idea.md", "stale-note.md", "should-we-keep-X.md"],
    openDecisions: ["should-we-keep-X.md"],
    nonCapture: ["findings/code-reviewer.md", "README.md"], absorbedDelta: 0
  };
  // Wrap the body in an async function so its top-level `return payload` is captured.
  const fn = new Function("agent","parallel","phase","log","args",
    "return (async () => { " + afterMeta + " })();");
  const payload = await fn(agent, parallel, phase, log, args);
  const out = {
    agentCalled,
    dropCount: payload.dropCount,
    promoteCount: payload.promoteCount,
    routeCount: payload.routeCount,
    moveIntents: payload.moveIntents,
    commitIntent: payload.commitIntent,
    vitalityLine: payload.vitalityLine,
    track: payload.track,
  };
  process.stdout.write(JSON.stringify(out));
' 2>&1) || { echo "  FAIL: runnable exercise errored — $EXERCISE"; FAIL=$((FAIL+1)); EXERCISE=""; }

if [ -n "$EXERCISE" ]; then
  # (a) agent never called on the deterministic path
  echo "$EXERCISE" | python3 -c "import json,sys;d=json.load(sys.stdin);assert d['agentCalled'] is False" 2>/dev/null \
    && ok "deterministic path ran with ZERO LLM (agent stub never called; AC-019)" \
    || ko "determinism runtime" "agent() was called on the deterministic path: $EXERCISE"

  # (b) DROP -> dropped/ via git mv, no delete; open decision -> promote
  echo "$EXERCISE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
mv=d['moveIntents']
drops=[m for m in mv if m['kind']=='drop']
promos=[m for m in mv if m['kind']=='promote']
assert all(m['op']=='git mv' for m in mv), 'a move intent is not git mv: %r'%mv
assert all('dropped/' in m['to'] for m in drops), 'a drop does not land in dropped/: %r'%drops
assert all('git rm' not in json.dumps(m) for m in mv), 'a move intent mentions git rm'
assert len(drops)==2 and d['dropCount']==2, 'expected 2 drops, got %r'%d['dropCount']
assert len(promos)==1 and d['promoteCount']==1, 'open decision must promote, not drop: %r'%promos
assert all('git rm' not in m.get('op','') for m in mv)
" 2>/dev/null \
    && ok "DROP -> visible dropped/ via git mv (no delete); open decision PROMOTES (AC-020)" \
    || ko "drop->dropped/" "drop/promote intents wrong: $EXERCISE"

  # (c) self-commit stages only touched paths (explicit), local, no push
  echo "$EXERCISE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
c=d['commitIntent']
assert c['local_only'] is True and c['push'] is False, 'self-commit must be local-only/no-push: %r'%c
assert c['stage']['mode']=='explicit-paths', 'must stage explicit paths, not -A: %r'%c
assert isinstance(c['stage']['addPaths'], list) and len(c['stage']['addPaths'])>0, 'no explicit addPaths: %r'%c
assert 'add -A' not in json.dumps(c) and '-A' not in ' '.join(c['stage']['addPaths']), 'git add -A leaked'
" 2>/dev/null \
    && ok "self-commit: local-only, explicit addPaths (never -A), no push (AC-021)" \
    || ko "scoped self-commit" "commit intent wrong: $EXERCISE"

  # (d) router moves findings/README OUT of the inbox to a non-inbox home
  echo "$EXERCISE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
mv=d['moveIntents']
routes=[m for m in mv if m['kind'].startswith('route')]
assert d['routeCount']==2 and len(routes)==2, 'expected 2 routed non-capture docs: %r'%routes
for m in routes:
    assert m['from'].startswith('docs/step-1-ideas/'), 'route source not in inbox: %r'%m
    assert not m['to'].startswith('docs/step-1-ideas/'), 'route target still in inbox: %r'%m
    assert m['op']=='git mv'
" 2>/dev/null \
    && ok "router moves findings/README OUT of the ideas inbox (deterministic; AC-022)" \
    || ko "non-capture router" "router intents wrong: $EXERCISE"

  # vitality line shape
  echo "$EXERCISE" | python3 -c "
import json,sys,re
d=json.load(sys.stdin)
v=d['vitalityLine']
assert re.match(r'^<!-- vitality: absorbed=\d+ passes=\d+ last=__DATE__ pending=\d+ -->$', v), 'bad vitality line: %r'%v
" 2>/dev/null \
    && ok "vitality line computed deterministically in the ADR-089 D5 format" \
    || ko "vitality line" "wrong shape: $EXERCISE"
fi

# --- cluster-floor determinism via the reused Wave C sweep-cluster.py ---------
if [ -f "$CLUSTER_PY" ]; then
  W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
  mkdir -p "$W/inbox"
  : > "$W/inbox/auth-login-redirect.md"
  : > "$W/inbox/auth-login-session.md"
  : > "$W/inbox/auth-login-token.md"
  : > "$W/inbox/unrelated-telemetry.md"
  R1=$(python3 "$CLUSTER_PY" cluster --inbox "$W/inbox" 2>/dev/null)
  R2=$(python3 "$CLUSTER_PY" cluster --inbox "$W/inbox" 2>/dev/null)
  if [ "$R1" = "$R2" ] && printf '%s' "$R1" | python3 -c "import json,sys;d=json.load(sys.stdin);assert isinstance(d['decision'],list)" 2>/dev/null; then
    ok "cluster floor is deterministic (sweep-cluster.py — identical inputs, identical groups; zero LLM)"
  else
    ko "cluster determinism" "R1=$R1 R2=$R2"
  fi
else
  ko "cluster floor script" "sweep-cluster.py not found (Wave C dependency)"
fi

echo
echo "=== Summary ==="
echo "sweep-engine: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
