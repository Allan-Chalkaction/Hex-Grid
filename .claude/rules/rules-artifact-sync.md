# Run Artifacts and State (Local-Only)

**HOOK-ENFORCED** — `sync-artifacts-post-agent.sh` (PostToolUse) manages all run state on the local filesystem. There is no remote sync.

## How It Works

The PostToolUse observer hook fires after every Agent and Write tool use. It has two responsibilities:

1. **Auto-state on `prompt.md` write** — When the orchestrator writes `prompt.md` to a recognized run folder, the hook extracts the ticket key (a freeform string label like `TA-037`) and creates the run state file at `.claude/agent-memory/active-runs/{session_id}-{slug}.json`. The LLM never writes state files.

2. **Agent completion tracking** — After each Agent completes, the hook appends `{type, at}` to a `completed_agents` array in the state file. The gate hook reads this locally to verify exploration, decomposition, and sequencing.

*(The v1 local plan-steps write arm — `spec-decomposer` output → `{run_dir}/plan-steps.json` — was removed with the phase state machine, ADR-079. `plan-steps.json` has no reader in any surviving track; durable run state is the thin manifest `run-manifest.json`, `tickets[]`.)*

## What's An Artifact

Anything the orchestrator or an agent writes into the run folder is an artifact. The standard layout:

```
docs/step-5-pipeline/YYYY-MM-DD/HHmm-{NIMBLE|WAVE|CHAIN|ROADMAP|PLANNER}-{slug}/
  prompt.md            # user request + ticket key
  spec.md              # pm-spec output (orchestrated)
  cto-evaluation.md    # cto-advisor output (orchestrated)
  adr.md               # architect-review output (orchestrated)
  ui-spec-addendum.md  # ui-spec output (optional)
  run-manifest.json    # thin manifest (engine paths; tickets[] for orchestrated) — ADR-039
  run-log.md           # wrap-up summary
  session-log.md       # ad-hoc notes
  findings/
    {agent-name}.md    # one file per agent invocation
```
*(`plan-steps.json` was the v1 decompose artifact — retired under the engine, replaced by `run-manifest.json`.)*

Files on disk **are** the artifacts. There is no separate sync target.

> **Surfacing notable artifacts to the operator.** This file owns the *layout* of run artifacts; **`core/rules/rules-artifact-surfacing.md`** owns the `SendUserFile` *on-write notification* convention for notable classes (jam READMEs, specs, ADRs, end-of-run run-log, locked roadmaps) — paired with **ADR-068** (the persist input-source extension that makes those artifacts newly reliable) and ADR-050 (its capture sibling). Scratch writes (per-turn run-log appends, `findings/*` the chain already streams, fixtures, manifest writes, drop-folder appends) are explicitly excluded.

## Ticket keys

A "ticket key" is a freeform string label (e.g. `TA-037`) the user puts in `prompt.md`. The observer hook
extracts the first `[A-Z]{2,4}-[0-9]{1,4}` match and stores it as `ticket_key` for traceability — not for
gating. The infra does not own ticket tracking; if a project uses an external tracker, reference the key in
`prompt.md`.

## Orchestrator Responsibilities

1. Create the run folder and write `prompt.md` with a ticket key in the content. Everything else is automatic.
2. Under the engine, there are no plan steps to mark — the Workflow script drives the chain and the thin `run-manifest.json` (`run-manifest.py`) records per-ticket status + commit SHAs. *(The v1 `plan-steps.json` active/complete-marking is retired.)*

## Close-out (binding)

**Location is status (ADR-087): a completed run does not stay in `step-5-pipeline/`.** Run completes →
`closeout-run.py` → MOVE + waiting-on-you render. The orchestrator runs the close-out verb —
`python3 core/scripts/closeout-run.py <run_folder> [--handoff <path>]` — which appends a `CLOSED:` line
to `run-log.md`, `git mv`s the run folder to `docs/step-6-done/<date>/<same-name>/`, moves an executed
handoff to `docs/step-6-done/handoffs/`, then renders the **waiting-on-you queue** (FOLLOWUP stubs +
delta counts, unexecuted PENDING handoffs, parked items). Idempotent (already-moved → no-op),
missing-source-tolerant (WARN + continue — ADR-066 §5e tolerances), stages only (never commits/pushes).
After the move, regenerate the dashboard (`python3 core/scripts/docs-index.py`). See
`docs/decisions/ADR-087-doc-lifecycle-location-is-status.md`.

**OUT-bookend scope gate (ADR-103 W3 — binding).** Before the MOVE, close-out set-diffs the run's decided
atoms (the thin manifest's `tickets[]`) against what shipped (ticket `status`). Any unaccounted atom
(`status != complete`) is **refluxed into `docs/step-1-ideas/from-<run-slug>/`** as a triage dossier stub,
and the **MOVE is HELD** (the run stays visibly in `step-5-pipeline/`, close-out exits 3) — a run cannot wrap
clean while leaving decided scope on the floor. Reflux is unconditional (the atom is never lost); the hold is
escapable with `--force-partial` (move anyway, atoms still refluxed). `--skip-scope-check` bypasses the gate.
Deterministic (the manifest IS the decided-atom set); fail-open on a malformed/absent manifest; nimble/no-`tickets[]`
runs skip naturally. On a HELD wrap, triage `from-<run-slug>/` (build / DEFER-rename / drop) then re-run, or
`--force-partial` for a deliberate partial wrap.
