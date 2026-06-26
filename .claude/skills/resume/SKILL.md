---
name: resume
description: "Resume an interrupted v2 run (nimble/orchestrated/chain) from its thin manifest"
user_invocable: true
---

## Resume a run (`/resume [slug]`)

Generic cross-session resume against the **thin manifest** (`{run_dir}/manifest.json`,
ADR-039). Replaces the v1 `pipeline-advance` for the Workflow-engine tracks: a run's
durable state is the manifest (chain, per-step status, commit SHA) — no phase state
machine to rehydrate.

> **Substrate path resolution (consumer-safe — ADR-031).** The substrate scripts below live at
> `core/scripts/…` when dogfooding inside claude-infra, but at `.claude/scripts/…` in a consumer
> repo (where `core/` is absent — they are symlinked under `.claude/`). A bare `core/…` path does
> NOT resolve in a consumer. Each Bash block resolves the prefix first
> (`S=.claude/scripts; [ -d "$S" ] || S=core/scripts`, then `$S/…`); when re-launching a preset via
> the `Workflow` tool, resolve `scriptPath` the same way (`.claude/scripts/workflows/<preset>.js`
> if it exists, else `core/scripts/workflows/<preset>.js`).

### 1. Resolve the run

```bash
# explicit slug, or newest manifest if omitted
if [ -n "$SLUG" ]; then
  MAN=$(ls -t docs/step-5-pipeline/*/*"$SLUG"*/manifest.json 2>/dev/null | head -1)
else
  MAN=$(ls -t docs/step-5-pipeline/*/*/manifest.json 2>/dev/null | head -1)
fi
[ -n "$MAN" ] || { echo "no manifest found for '$SLUG'"; exit 1; }
D=$(dirname "$MAN")
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
$S/run-manifest.py read "$MAN"
```

### 2. Branch on state

First, branch by track. A run with a `tickets[]` array is **orchestrated**; otherwise it is a
single-chain run (**nimble**).

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
TRACK=$($S/run-manifest.py read "$MAN" | python3 -c "import json,sys;print(json.load(sys.stdin).get('track','nimble'))")
```

#### Single-chain (nimble / chain)

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
NEXT=$($S/run-manifest.py next "$MAN")
```

- **`COMPLETE`** → nothing to do. If `commit_sha` is null, the only remaining work is the
  commit; offer to commit. Otherwise report the run is finished.
- **`BLOCKED:<phase>`** → a step failed (gate agent died, implementer REFUSED, etc.). Read
  that step's `note` in the manifest + the relevant `findings/` file, surface the blocker
  to the operator with a recommended action, and await disposition. Do NOT auto-re-run a
  blocked step — the prior attempt failed for a reason the operator should see.
- **a phase name** (e.g. `gate`) with run status `surfaced` → re-print the
  `criterionFindings` surface from `findings/` and await the operator's disposition
  (the run halted at a consolidated surface). On disposition, apply, then `set-status
  complete` (which clears `surface_required`) and continue.
- **a phase name** with run status `running` → the run was interrupted mid-chain. Re-run the
  track's preset script (resolved per the path note: `.claude/scripts/workflows/…` in a consumer,
  else `core/scripts/workflows/…`): **nimble** → `nimble.js`; **chain** →
  `chain.js` (rebuild the `agents` list from the manifest's step labels —
  each step is `NN-<agent>` — and the task from `prompt.md`). In-place implement is idempotent for
  a well-scoped task and the gate re-validates. Then persist artifacts + surface/commit per the
  owning skill's steps 3–5 (`/nimble` or `/chain`).

#### Orchestrated (multi-ticket — manifest `tickets[]`)

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
NEXT_T=$($S/run-manifest.py next-ticket "$MAN")
```

- **`COMPLETE`** → every ticket complete. If run status is `surfaced`, re-print the
  `criterionFindings` surface from `findings/` (the wave halted at a gate/architect-final surface)
  and await disposition. Else if `commit_sha` is null, the only remaining work is the wave-level
  commit; offer to commit per `core/skills/orchestrated/SKILL.md` step 5. Otherwise the wave is done —
  run the close-out verb (resolved per the path note: `python3 .claude/scripts/closeout-run.py <run_dir> [--handoff <path>]` in a consumer, else `core/scripts/closeout-run.py`) to MOVE the
  run folder to `step-6-done/` and render the waiting-on-you queue (ADR-087 D2.3; `rules-artifact-sync.md`).
- **`BLOCKED:<key>`** → that ticket failed (implementer REFUSED/blocked, or a stale-base
  integration refusal). Read its `findings/implementer-<key>.md` (or `findings/integrate.md`) + the
  manifest ticket `note`, surface the blocker with a recommended action, and await disposition. Do
  NOT auto-re-run a blocked ticket.
- **`WAITING:<key>`** → a dependency stall (the lowest incomplete ticket is gated on an incomplete
  dependency and nothing else is dep-ready). Surface it — usually it means an upstream ticket is
  `blocked`; resolve that first.
- **a ticket key** (e.g. `T-003`) → the first dep-ready, non-complete ticket. Re-launch the wave from
  there: re-run the orchestrated preset (`.claude/scripts/workflows/orchestrated.js` in a consumer,
  else `core/scripts/workflows/orchestrated.js`) (the worktree implementers are idempotent
  for well-scoped tickets; already-`complete` tickets are skipped by `next-ticket`), then persist +
  surface/commit per `core/skills/orchestrated/SKILL.md` steps 3–5. The wave branch and its prior
  per-ticket commits are the durable resume substrate — `git log --oneline "$WAVE_BRANCH"` shows what
  already landed.

### 3. Synthesize session state if needed

If a hook-managed state file is required for the track, synthesize a fresh
`.claude/agent-memory/active-runs/${SESSION_ID}-${slug}.json` via the standard
prompt.md / Bash path (mirrors the v1 `pipeline-advance` synthesis). For pure
Workflow-engine runs the manifest is sufficient and no state file is needed.

## Notes

- The manifest is the single source of truth; the chain is re-derivable, the artifacts
  are on disk. A fresh session can resume with only the slug.
- `next` returns the first step whose status != `complete`, so a `complete` step is never
  re-run.
- This skill is advisory glue: it reads the manifest and routes; it does not itself
  dispatch implementers (the track's preset script does).
