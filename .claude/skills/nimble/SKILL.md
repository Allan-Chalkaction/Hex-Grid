---
name: nimble
description: "Start a nimble-track run on the v2 Workflow engine (explore -> implement -> batch-gate)"
user_invocable: true
---

## Starting a Nimble Run (v2 — Workflow engine)

Post engine-swap (ADR-039), the nimble track runs as a **native Workflow script**
(`core/scripts/workflows/nimble.js`), not the bespoke phase state machine. The chain
logic lives in ~40 lines of script that never enters the orchestrator's per-turn
context — that is the token win (T4 spike: orchestrator output −86%, 0 surfaces,
quality held).

The orchestrator drives five steps. **Steps 1 and 3 are load-bearing and MUST NOT be
skipped** — the Workflow script has no filesystem access and `Explore` agents cannot
`Write`, so knowledge artifacts are persisted by the orchestrator, not the chain.

> **Substrate path resolution (consumer-safe — ADR-031).** The substrate scripts below live at
> `core/scripts/…` when dogfooding inside claude-infra, but at `.claude/scripts/…` in a consumer
> repo (where `core/` is absent — they are symlinked under `.claude/`). A bare `core/…` path does
> NOT resolve in a consumer. Every Bash block that calls one resolves the prefix first
> (`S=.claude/scripts; [ -d "$S" ] || S=core/scripts`, then `$S/…`). For the `Workflow` tool's
> `scriptPath`, pass `.claude/scripts/workflows/nimble.js` if that path exists, else
> `core/scripts/workflows/nimble.js`.

### 1. Create the run folder + prompt.md — via **Bash**, not the Write tool

```bash
SLUG="<kebab, <=4 words>"; D="docs/step-5-pipeline/$(date +%Y-%m-%d)/$(date +%H%M)-NIMBLE-$SLUG"
mkdir -p "$D/findings"
BASE_REF="$(git rev-parse HEAD)"   # stable base for the integrate staleness guard + gate diff (ADR-046)
cat > "$D/prompt.md" <<'EOF'
# <title>
Ticket key: <KEY>
<verbatim user request>
EOF
```

Use **Bash heredoc** (not the Write tool) so the v1 auto-fire hook
(`sync-artifacts-post-agent.sh`, PostToolUse on the Write tool) does NOT trigger the
legacy state machine. The v2 engine owns its own lifecycle.

### 2. Launch the Workflow engine

Invoke the `Workflow` tool with the resolved nimble-script `scriptPath` (per the path-resolution
note above: `.claude/scripts/workflows/nimble.js` in a consumer, else `core/scripts/workflows/nimble.js`)
and `args` = `{ runDir: "$D", repoRoot: "<abs repo root>", task: "<the task + ACs>",
baseRef: "$BASE_REF", baseSha: "$BASE_REF",
contextual: <null | "ui-review" | "db-migration-reviewer" | "security-auditor"> }`.

Pick `contextual` by file type (D5): UI → `ui-review`; migration → `db-migration-reviewer`;
auth/secrets → `security-auditor` (auto-add this one on any auth/secret/migration surface,
ADR-018 crit-3). Otherwise `null`. code-reviewer + spec-conformance always run. `baseRef` is the
pre-launch working-branch HEAD (the integrate staleness guard + gate diff use it; absent → degraded
fallback to current HEAD).

`baseSha` is the working-branch tip SHA captured at invocation (`$BASE_REF` above is exactly
`git rev-parse HEAD` on the working branch, so pass it for both). The engine embeds it as an
**unconditional STEP 0** in the implement brief (`git fetch . && git reset --hard <baseSha>` before
any work) so the implementer's worktree starts from the dispatch-time tip rather than stale
session-start state (ADR-085 D2). Absent → the brief falls back to the protocol base-check guard
language; the engine has no git/FS access, so the SHA must arrive in `args` (ADR-039 contract 2).

The chain runs autonomously: explore ∥ → implement (**worktree**, ADR-046) → integrate
(staleness-guarded `--no-ff` merge into the working branch) → batch-gate. It returns a structured
payload (`exploreMap`, `implementation`, `integrate`, `review`, `conformance`, `allFindings`,
`criterionFindings`, `surfaceRequired`). The implementer runs in an isolated worktree (so
`block-source-edits.sh` permits source writes); the deliverable is on the working branch after
integrate.

### 3. Persist artifacts (FLAG-1 — **mandatory, never skip**)

Write the workflow return to a temp file, then:

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
$S/persist-run-artifacts.py --run-dir "$D" --slug "$SLUG" \
  --task "<short task label>" --chain "explore,implement,integrate,gate" \
  --return-file /tmp/nimble-return.json
```

This materializes `findings/*`, `run-log.md`, and the **thin manifest** `manifest.json`
from the return. Inspect the printed `run_status`.

### 4. Consolidated surface (only if `surfaceRequired`)

- `surfaceRequired: false` → auto-dispose: all findings are `criterion_match: none`. Log
  is already in `findings/`. Proceed to commit.
- `surfaceRequired: true` → surface **once**, batched: print the `criterionFindings` list
  with the recommended disposition per item, and **halt** (the manifest is
  `surfaced`/`gate: blocked`). Resume later via `/resume <slug>`. Do NOT loop per-finding
  (ADR-036). The five ADR-018 criteria are the only halt reasons.

### 5. Commit

The deliverable is **already on the working branch** (the worktree implementer's commit was merged by
the integrate step). When not surfaced (or after the operator dispositions a surface), commit the
run-folder artifacts and record the integrated SHA (`integrate.integrated_head` from the return):

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
git add "$D" && git commit -m "chore(nimble-$SLUG): run artifacts"
$S/run-manifest.py set-sha "$D/manifest.json" "<integrate.integrated_head>"
```

## Phase sequence

`explore ∥ → implement (worktree) → integrate (staleness-guarded --no-ff merge) → batch-gate (code-reviewer ∥ spec-conformance [∥ contextual])`

No `spec.md`/decompose step in the default nimble chain — the spec is the prompt + what
explore finds. (Author a `spec.md` first only if the task genuinely needs one; the chain
reads it if present.) Quality gates are **in the chain**, not manual.

## When to use nimble vs orchestrated

Nimble = a single, well-understood feature/fix one implementer completes end-to-end.
For new features needing CTO + ADR + multi-ticket decomposition, use `/orchestrated`.
If the `implementer` REFUSES for scope, escalate to `/orchestrated`.

## Resume

A nimble run interrupted at a surface (or across sessions) resumes via `/resume <slug>` —
it reads the thin manifest and continues from the first non-complete step.
