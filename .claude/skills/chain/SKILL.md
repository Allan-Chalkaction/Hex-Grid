---
name: chain
description: "Run a custom agent chain on the v2 Workflow engine — /chain a,b,c runs an operator-supplied ordered agent list under the shared autonomy contract + consolidated surface (D6)"
user_invocable: true
---

## Starting a Custom Chain (`/chain a,b,c` — v2 Workflow engine)

The custom chain (D6) is the "you name the agents" path: you declare an ordered agent
sequence and the orchestrator runs it under the **same shared autonomy contract +
consolidated surface (ADR-036)** as nimble/orchestrated. It runs as a **native Workflow
script** (`core/scripts/workflows/chain.js`) — a thin layer over the T5a engine core
(ADR-039/040), so it inherits the four engine contracts unchanged.

**The command is the door; pasting the sequence in a prompt is the fallback** (D6). Both
reach the same `chain.js`.

The orchestrator drives a small number of steps. **The persist step (3) is load-bearing and
MUST NOT be skipped** — the Workflow script has no filesystem access and read-only agents
(e.g. `Explore`) cannot `Write`, so knowledge artifacts are persisted by the orchestrator from
the structured return (FLAG-1).

> **Substrate path resolution (consumer-safe — ADR-031).** The substrate scripts below live at
> `core/scripts/…` when dogfooding inside claude-infra, but at `.claude/scripts/…` in a consumer
> repo (where `core/` is absent — they are symlinked under `.claude/`). A bare `core/…` path does
> NOT resolve in a consumer. Every Bash block that calls one resolves the prefix first
> (`S=.claude/scripts; [ -d "$S" ] || S=core/scripts`, then `$S/…`). For the `Workflow` tool's
> `scriptPath`, pass `.claude/scripts/workflows/chain.js` if that path exists, else
> `core/scripts/workflows/chain.js`.

### 0. Parse the chain

`/chain a,b,c` → the comma-separated list IS the ordered agent sequence (e.g.
`/chain cto-advisor,architect-review,implementer,code-reviewer`). Each agent is
**role-classified** automatically:

- **gate** — `code-reviewer`, `spec-conformance`, `security-auditor`, `ui-review`,
  `db-migration-reviewer`, `performance-reviewer`, `accessibility-auditor` → schema-forced
  findings (drive the consolidated surface).
- **implement** — `implementer`, `frontend-implementer`, `backend-implementer`,
  `nimble-implementer`, `wave-implementer` → edits files **in place**, returns a COMPLETION_REPORT.
- **think** — everything else (`cto-advisor`, `architect-review`, `pm-spec`, `ui-spec`,
  `Explore`, `spec-decomposer`, …) → free-form analysis fed forward to later steps.

To override a role (e.g. force `architect-review` to emit findings), pass the structured
`agents` form: `[{ "agent": "architect-review", "role": "gate" }, ...]`.

### 1. Create the run folder + prompt.md — via **Bash**, not the Write tool

```bash
SLUG="<kebab, <=4 words>"; D="docs/step-5-pipeline/$(date +%Y-%m-%d)/$(date +%H%M)-CHAIN-$SLUG"
mkdir -p "$D/findings"
cat > "$D/prompt.md" <<'EOF'
# <title>
Ticket key: <KEY>
Chain: <a,b,c>
<verbatim user request + standing instructions>
EOF
```

Use **Bash heredoc** (not the Write tool) so the v1 auto-fire hook
(`sync-artifacts-post-agent.sh`, PostToolUse on the Write tool) does NOT trigger the legacy
state machine. The v2 engine owns its own lifecycle.

### 2. Launch the Workflow engine

Invoke the `Workflow` tool with the resolved chain-script `scriptPath` (per the path-resolution
note above: `.claude/scripts/workflows/chain.js` in a consumer, else `core/scripts/workflows/chain.js`)
and `args`:

```json
{
  "runDir": "$D",
  "repoRoot": "<abs repo root>",
  "task": "<the task + ACs>",
  "agents": ["cto-advisor", "architect-review", "implementer", "code-reviewer"],
  "contextual": null
}
```

- `agents` (required) — the ordered list (strings, or `{agent, role}` objects to override role).
  A comma-joined string is also tolerated as a fallback shape.
- `contextual` (string | array, optional) — extra **gate-role** reviewers appended at the end of
  the chain (parity with `/nimble`). Pick by file type; otherwise `null`.

The chain runs autonomously in order — each agent sees the task + the accumulated outputs of
every prior step (front-loaded thinking → implement → gate). It returns a structured payload
(`track:"chain"`, `agents`, `steps`, `allFindings`, `criterionFindings`, `surfaceRequired`).

### 3. Persist artifacts (FLAG-1 — **mandatory, never skip**)

Write the workflow return to a temp file, then:

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
$S/persist-run-artifacts.py --run-dir "$D" --slug "$SLUG" \
  --task "<short task label>" --return-file /tmp/chain-return.json
```

This materializes `findings/{NN}-{agent}.md` (one per chain step), `run-log.md`, and the **thin
manifest** `manifest.json` (`track:"chain"`; the agent labels are the chain steps). Inspect the
printed `run_status`.

### 4. Consolidated surface (only if `surfaceRequired`)

- `surfaceRequired: false` → auto-dispose: all findings are `criterion_match: none` (or the chain
  had no gate). Proceed to commit.
- `surfaceRequired: true` → surface **once**, batched: print the `criterionFindings` list with the
  recommended disposition per item, and **halt** (the manifest is `surfaced`; the offending step is
  `blocked`). Resume later via `/resume <slug>`. Do NOT loop per-finding (ADR-036). The five
  ADR-018 criteria are the only halt reasons.

### 5. Commit

When not surfaced (or after the operator dispositions a surface), commit the deliverable (if the
chain included an implement step) + run folder, then record the SHA:

```bash
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
$S/run-manifest.py set-sha "$D/manifest.json" "<sha>"
```

## When to use a custom chain

When neither nimble's fixed `explore → implement → gate` nor orchestrated's full
`cto → architect → … → architect-final` is the right shape — e.g. an analysis-only chain
(`cto-advisor,architect-review,pm-spec`), a backend-then-migration-review chain
(`backend-implementer,db-migration-reviewer`), or any bespoke sequence you want to run once under
the autonomy contract. For a single well-understood change use `/nimble`; for a full multi-ticket
wave use `/orchestrated`.

## Resume

A chain interrupted at a surface (or across sessions) resumes via `/resume <slug>` — it reads the
thin manifest and continues from the first non-complete step (the single-chain resume path, which
`chain` shares with nimble).
