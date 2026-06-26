---
name: planner
description: Start a planner session — the operator's repo-aware planning partner. Drafts plans, ticket/gate/reply prompts, ADR drafts, and handoffs as files; routes into /research, /roadmap, feature-decomposition, adr. Advisor-only (no implementers, no source edits — enforced even under bypass). A first-class entry mode alongside /nimble, /orchestrated, /chain, /bypass, /roadmap.
user_invocable: true
---

# Planner Mode — the operator's planning partner

`/planner` configures this session as the **planner**: a repo-aware planning surface that replaces
the external claude.ai planning loop. It reads the repo natively, drafts paste-ready artifacts to
files, checks CC halts against ADR-018, and routes into the existing planning skills. It is
**advisor-only** — it never edits application source or dispatches implementers (enforced by the
planner write-hook, which holds **even under `/bypass`** — ADR-032).

This is one of the entry modes:

- `/nimble` — quick / single-feature work (light engine preset)
- `/orchestrated <slug>` — heavy engine preset; autonomous wave execution (builds a planned wave)
- `/chain a,b,c` — custom ordered agent chain on the engine
- `/bypass` — just chat; no protocol, no run folder
- `/roadmap` — iterative epic→roadmap / wave→spec planning
- `/planner [slug]` — persistent planning partner (this skill)

**Contract:** `core/rules/rules-advisory-modes.md`. **Persona:** `core/agents/planner.md`.
**Rationale:** `docs/decisions/ADR-032-planner-track.md`.

## Usage

- `/planner [slug]` — start (or resume) a planner session. `slug` is an optional session label;
  defaults to `session`.
- `/planner off` — end the session (removes the state file; run folder persists).

## On Invocation

### Start (or resume)

1. Parse the arg. `off` → run "End" below. Otherwise `SLUG="${arg:-session}"`.
2. If an in-progress `${SESSION_ID}-*.json` planner state file already exists for this session, or a
   `*-PLANNER-*${SLUG}*` run folder exists, **RESUME**: read the latest artifacts in that run folder
   and continue. Do not start a fresh folder.
3. Otherwise create the run folder:
   ```bash
   DATE=$(date +%Y-%m-%d); TIME=$(date +%H%M)
   RUN_DIR="docs/step-5-pipeline/${DATE}/${TIME}-PLANNER-${SLUG}"
   mkdir -p "${RUN_DIR}/findings"
   ```
4. **Write `${RUN_DIR}/prompt.md` with the Write tool** (NEVER a shell heredoc — the observer hook
   that auto-creates the state file fires on the Write tool, not on Bash). Include a ticket-key-shaped
   label if the operator gave one. The hook creates the state file with `track:"planner"`,
   `current_phase:"planner-loop"` — which also satisfies the track-selection gate so bare prompts
   flow without `/bypass` or `@`-prefixing (resolves BL-015).
5. **Read `core/agents/planner.md`** — your operating contract — then drop into the planner loop.

### End (`/planner off`)

Remove **this session's** planner state file with a **single-line** Bash `rm`, globbing on the run
**slug** from the active `WORKFLOW STATE MACHINE` injection (the `Slug:` line — e.g. `1620-session`).
The slug is unique to this run and, unlike `${SESSION_ID}`, needs no subshell expansion
(`${SESSION_ID}` does **not** expand in the Bash-tool subshell — INFRA-012; that, plus a `${arg}`
slug that drifts from the real `HHmm-`prefixed slug, is what made the old teardown silently no-op).

```bash
# Substitute the injection's `Slug:` value for <slug>. MUST be a single, un-chained rm — this is the
# exact shape the planner write-hook's teardown carve-out permits; a multi-line loop or a `;`-chained
# command is refused. Bash rm, NOT Edit/Write — block-active-runs-edits.sh blocks the tools, not Bash.
rm -f .claude/agent-memory/active-runs/*-<slug>.json
```

The slug glob is session-scoped (the run slug is unique to this run) and immune to the
`${SESSION_ID}` / slug-default failure modes. Confirm: "Planner session ended. Run folder +
artifacts persist for review or resume."

### Jam sub-mode — RETIRED (jam convergence moved to `/sweep`, ADR-112 Wave 3)

The `/planner jam <topic>` sub-mode is **retired** (PEC-T9). Jam clustering + convergence — open/reopen a
`docs/step-2-planning/jam-<slug>/` workspace, prune into a fork-resolving thesis, maintain the vitality line —
now live **in-skill in `/sweep`** (`core/skills/sweep/SKILL.md` § "Jam convergence"), reached by the
`ingest-to-jam` / `new-cluster` verdicts. To converge a jam, run **`/sweep`** — not `/planner jam`.

Plain `/planner [slug]` is **unchanged** (the general planning partner; advisor-only, write-scoped to
`docs/**` + `core/rules/**`). It simply no longer carries a jam sub-mode. (ADR-049 records the original
`/planner jam` design; ADR-112 Wave 3 records the move to `/sweep`. The graduated-jam `ARCHIVED-` filename
convention is documented with the convergence door it belongs to.)

## Behavior during the session

Defined by `core/agents/planner.md` (persona) + `core/config/phases/planner/planner-loop.md`
(injected each turn) + `core/rules/rules-advisory-modes.md` (contract). In short: advisor-only,
write-scoped to planning artifacts, file-first output to `${run_dir}`, verify-by-view default,
halt only on ADR-018 criteria, route into existing skills.

## Bypass overlay

If `/bypass` is also active, bypass lifts protocol *gating* (all agents pass) but the planner
write-hook still refuses source edits — gating and role-scope are orthogonal primitives (ADR-032).
The run folder, artifacts, and `completed_agents[]` accumulation continue.

## When to use it

- A planning session where you want repo-aware drafting (decomposition plans, ticket prompts, CC
  reply prompts, ADR drafts) without window-bouncing to an external planner.
- Reviewing a CC halt against ADR-018 and drafting the paste-ready reply.
- Front-half planning that routes into `/research`, `/roadmap`, `feature-decomposition`, `adr`.

## When NOT to use it

- **Building** anything → `/nimble`, `/chain a,b,c`, or `/orchestrated <slug>`.
- **Iterative epic/wave planning specifically** → `/roadmap` (the structured round-loop). `/planner`
  is the general partner; it routes into `/roadmap` when that structure fits.
- **A one-shot advisor opinion** → `/bypass` + `@<agent>`.
