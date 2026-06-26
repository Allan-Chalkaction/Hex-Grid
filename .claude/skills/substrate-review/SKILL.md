---
name: substrate-review
description: "Periodic modernization self-assessment of the claude-infra substrate (what's now native / where it drifted from best practice / what to cut). Advisor-only, READ-ONLY. Composes with /doctor (health) and /upgrade (distribution) — does not duplicate them. Triggers: \"/substrate-review\", \"is the substrate still best-in-class\", \"what's now native\", \"modernization scan\", \"should we cut anything\"."
user_invocable: true
---

# Substrate review — periodic modernization assessment

Claude Code evolves continuously. Capabilities you hand-built can become native; best practice
shifts; accretion accumulates. This skill re-runs the structured assessment that produced the
v1→v2 rethink, on a cadence (recommend quarterly, or whenever a major Claude Code release lands).

It answers three questions:
1. **Now-native** — what did we build that the platform now does natively (subagents, worktrees, the
   Workflow tool, looping/Ralph, background agents, agent teams, plan mode, sessions/resume)?
2. **Drift** — where have we diverged from current multi-agent best practice (over-gating, too many
   agents, per-turn payload bloat, missing Tier 2/3 orchestration)?
3. **Cut** — what's orphaned, duplicated, or overcomplex and should be merged/deleted?

## What it does NOT do

- It does **not modify** the substrate. Read-only; produces recommendations only.
- It does **not** check health (`/doctor`) or distribute (`/upgrade`) — it *calls* `/doctor` for the
  health slice and folds the verdict in by reference; it never reimplements them (compose, don't
  duplicate).

## Procedure

### 1. Create the run folder — via **Bash**, not the Write tool

```bash
D="docs/step-5-pipeline/$(date +%Y-%m-%d)/$(date +%H%M)-SUBSTRATE-REVIEW"
mkdir -p "$D/findings"
```

Bash (not the Write tool) so the v1 auto-fire hook (`sync-artifacts-post-agent.sh`, PostToolUse on
Write) does not trigger the legacy state machine. This skill is advisor-only — no run state file.

### 2. Fan out four read-only assessors (parallel; single message)

Dispatch four assessors **in parallel** (Explore or general read-only agents — never an implementer;
read-only is the safety contract). Each writes a structured assessment the orchestrator persists to
`${D}/findings/`:

- **Agents** (`findings/assess-agents.md`) — roster table (purpose / model / line-count / wired-in? /
  tier), overlap clusters, orphans (defined-but-never-dispatched), gaps, overcomplexity.
- **Skills + commands** (`findings/assess-skills-commands.md`) — entry-mode / quality-gate /
  maintenance / utility inventory, redundancy, command↔skill duplication, keep/merge/cut table.
- **Execution engine** (`findings/assess-engine.md`) — chain/preset map (Workflow scripts + the thin
  manifest), token-cost autopsy, interrupt/halt density, layer accretion, the irreducible core.
- **Hooks + rules** (`findings/assess-hooks-rules.md`) — hook inventory (event / per-turn cost), rules
  payload sizes + per-turn total, the enforcement web, simplification candidates.

Scope each assessor to its layer and instruct **conclusions + tables, not file dumps**.

### 3. Web-research the moving target (parallel with step 2 where possible)

Dispatch a research step (WebSearch / WebFetch, e.g. via a general-purpose agent) to capture, for the
**current month**: (a) Claude Code's current native features, and (b) prevailing multi-agent workflow
best practices. Return a **"now-native vs what-we-built"** comparison. Persist to
`findings/web-research.md`. "Native" is a moving target — this step is mandatory on every run.

### 4. Call `/doctor` for the health slice

Run `/doctor` (or invoke its logic) and fold the verdict in **by reference** — do not re-run the
synthetic suite or re-implement hook/registration checks here. `/doctor` owns health; this skill owns
modernization.

### 5. Synthesize `findings-v1.md` (`-vN` on re-runs)

Write `${D}/findings-v1.md` with:
- **Bottom line** — is the substrate still best-in-class? The 3–5 highest-leverage moves.
- **Now-native table** — `Capability | What we built | Now native? | Migration recommendation`.
- **Token / interrupt autopsy** — per-turn cost + halt density vs. the irreducible core.
- **Best-practice drift** — where we diverge from current multi-agent guidance.
- **Keep / merge / cut** — per layer (agents / skills / commands / hooks / rules), with rationale.
- **Recommended sequencing** — the order to act, and what to defer.
- **`/doctor` verdict** — folded in by reference (health is not re-derived here).

### 6. Stop at the findings

Present a tight chat summary + the 3–5 highest-leverage decisions for the operator. **Do not build.**
This skill ends at recommendations; acting on them is a separate `/nimble` / `/orchestrated` / `/chain`
run (and distribution is `/upgrade`).

## Output

- `findings-v1.md` (and `-vN` on re-runs).
- Per-assessor notes under `findings/` (`assess-agents.md`, `assess-skills-commands.md`,
  `assess-engine.md`, `assess-hooks-rules.md`, `web-research.md`).
- A one-paragraph chat summary + the 3–5 highest-leverage decisions.

## Cadence guidance

- **Quarterly** by default, or on a **major Claude Code release**.
- Always re-run the web-research step — "native" is a moving target.
- Compare against the prior run's `findings-v{N-1}.md` to show what changed since last time.

## Cross-references

- `/doctor` — health (compose, don't duplicate).
- `/upgrade` — distribution (act on what review + doctor recommend).
- The reference run that defined this exercise:
  `docs/step-5-pipeline/2026-06-06/1221-PLANNER-substrate-rethink/`.
