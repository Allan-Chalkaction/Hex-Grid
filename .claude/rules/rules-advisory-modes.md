# Advisory Modes — Orchestrator Authority (roadmap · planner)

Two entry modes share one shape: **advisor-only, named-track runs that accumulate findings/artifacts
without dispatching implementers or editing application source.** This file is their merged binding
contract. Rationale, alternatives, and dogfood history live in the paired ADRs — never inline them here.

- `/roadmap [wave-N]` — iterative epic→roadmap (Phase E) / wave→spec (Phase W) planning (ADR-030/035).
- `/planner [slug]` — repo-aware planning partner; role-scoped write-hook (ADR-032/033).

---

## Shared contract (both)

**Authorities granted.** Dispatch advisor-tier agents (`@cto-advisor`, `@architect-review`, `@ui-spec`,
`@pm-spec`, `@code-reviewer`, `@security-auditor`, …) and Explore agents; accumulate findings under
`${run_dir}/findings/{agent}.md` (`.iter-N` suffix on same-agent re-invocation — the original is never
overwritten). Write planning artifacts to the run folder and to canonical doc destinations. Halt-and-resume
across sessions.

**Authorities NOT granted.** Dispatch implementer-tier agents (`implementer`,
`wave-implementer`) — blocked by `require-protocol.sh`'s per-track arm. Bypass
user authorization for shared-state operations (push, force, PRs, external posts) — universal, unaffected.
Skip stop-points or scope-clarification rules.

**Findings accumulation** rides the existing PostToolUse mkdir-mutex path in `sync-artifacts-post-agent.sh`
(`completed_agents[]` appends per agent) — no hook change per mode.

**Bypass transparent overlay (roadmap).** When `/bypass` is also active, the bypass short-circuit
in `require-protocol.sh` fires first — all agents pass regardless of track arm. Bypass does NOT mutate the
mode's state file; the run folder, findings, and `completed_agents[]` continue. On `/bypass off` mid-session
the phase-boundary check and the implementer block resume. **Planner is the exception — see its role-purity
invariant below.**

**State teardown.** `/<mode> off` removes the state file via Bash `rm -f` (NOT Edit/Write —
`block-source-edits.sh`'s active-runs guard blocks the tools, not Bash). Run folder + artifacts persist.
State files are session-scoped (`{session_id}-{slug}.json`); cleared at SessionStart by `session-cleanup.sh`.

---

## /roadmap — iterative planning (ADR-030; round enrichment ADR-035)

**Operating contract — autonomous-to-completion (ADR-054).** A `/roadmap` run is a **single forward pass**:
funnel → planner self-QA → finalize the canonical artifact, in one turn, with **no human-tuning rounds and
no operator-lock gate**. The funnel runs autonomously (no mid-funnel pickers, no "checking in"); the ONLY
stops are ADR-018 criteria 1/2/3/5. Defensible options (including a `cto-advisor` SIMPLIFY) are
picked-and-documented by the owning agent and folded into the draft — they do not block finalization.
`CONTINUE`-class planner tunings that aren't mechanically applied are recorded as an `## Open refinements`
section in the finalized doc. **Exit is orchestrator completion** (the canonical `roadmap.md` / wave files
written), not operator lock. *The legacy multi-round operator-lock loop is preserved behind `--attended`
(`attended: true` in `prompt.md`) for when the operator wants to tune live.*

**Two phases (state-aware, single command).** Phase E vs W is an entry-point distinction re-derived from
disk each turn; both share the round-loop protocol.

| | Phase E (Altitude A) | Phase W (Altitude B) |
|---|---|---|
| Trigger | `/roadmap` (no wave arg), no roadmap on disk | `/roadmap wave-N`, roadmap exists |
| Input | jam brief (`docs/step-2-planning/jam-<slug>/`) if present, else epic intent paste (intake template) | the wave's fat skeleton from the roadmap |
| Funnel | research (Explore) → decomposition (orchestrator + `@cto-advisor`) → fat-skeleton authoring | `@cto-advisor` → `@architect-review` → `@ui-spec` → `@pm-spec` (pm-spec LAST, as integrator) |
| Output (on lock) | `docs/step-3-specs/<epic-slug>/roadmap.md` | `docs/step-3-specs/<epic-slug>/waves/<wave-slug>/` (`<wave-slug>.md` + `-prompts.md`) |

**Per-round protocol.**
1. Run the round's funnel autonomously to completion (only ADR-018 1/2/3/5 interrupt).
2. Write `round-N-draft.md` to disk.
2b. **Round-boundary enrichment (ADR-035).** Before presenting, dispatch the read-only `planner` subagent
   on the round draft → it writes `findings/round-N-recommended-reply.md` (paste-ready answers + a
   `LOCK`/`CONTINUE` recommendation). Enrichment recommends only — it NEVER locks or advances. Benign
   failure → present un-enriched. Idempotent (resume-safe).
3. Present: what changed from round N-1; the draft; choices made with rationale; the recommended-reply
   section; explicit tuning prompts.
4. **Halt at the round boundary** — end the turn.
5. On input: lock → exit contract; tuning → write `round-N-operator-input.md`, run round N+1; direct-edit
   (Phase E) → diff is the input.

Research cadence: full research at round 0; re-run only when tuning changes scope (orchestrator judges +
documents). Soft cap ~10 rounds (surface a note; no hard cap).

**Durable-artifact discipline (non-negotiable).** Conversation history is not a substrate. Every round
writes to disk under `docs/step-5-pipeline/YYYY-MM-DD/HHmm-ROADMAP-{epic-<slug>|wave-<N>-<slug>}/`:
`round-0-intent.md`, `round-N-draft.md`, `round-N-operator-input.md`, … `locked.md`, `findings/{agent}.md`.
**Resume invariant (load-bearing):** on `/roadmap <slug>`, read the highest `round-N-draft.md` and continue
at round N+1 — NEVER restart at round 0 when drafts exist. Covered by `core/scripts/test-roadmap-mode.sh`.

**Intake discipline (Phase E).** Intent is sourced **jam-first, paste-second** (ADR-051 §8). As of ADR-065
the jam-seeded path is **script-captured engine-side** — the engine's `intent-capture` step (the first
Phase-E step) dispatches `pm-spec` to read the jam (`README.md`, fallback `index.md`, + every `source/*.md`)
and ground it by-view; the orchestrator/skill no longer hand-authors the intent doc. If a jam exists at
`docs/step-2-planning/jam-<epic-slug>/`, its converged brief **IS** the epic intent (`intentSource: "capture"`,
the Phase-E default) — **no paste demanded**, and the **feasibility-claim guard is satisfied by the engine's
verify-by-view at capture time** (ADR-051 §8). Phase E MUST check for the jam before asking the operator to
paste. The **paste path is the back-compat escape hatch** preserved as `intentSource: "curated"` (paste rides
through verbatim, zero capture dispatch). **The `[CC to verify]` feasibility guard now narrows to the PASTE
PATH ONLY:** when no jam matches and the operator pastes, the intent paste MUST NOT assert how existing code
is structured (files, functions, tables, shipped capabilities); on detecting a feasibility claim at ingest,
HALT (session-start, not a mid-round picker) and ask the operator to re-author it as a `[CC to verify]`
deferral the research pass answers. A jam may also feed a build directly (`intentSource: "jam-direct"`,
ADR-051 §9) — a verbatim short-circuit, no capture dispatch. (ADR-065.)
**claude.ai owns intent; CC owns feasibility-grounding.**

**Authorities NOT granted (beyond shared).** Author intent or assert feasibility in the operator's place;
dispatch implementer-tier agents; pick mid-funnel (defensible options are pick-and-document). *(Autonomous
finalization IS now granted — ADR-054 — for the canonical roadmap/wave `docs/**` artifact only; it remains
advisor-only and writes no source.)*

**State lifecycle.** `/roadmap` (E) creates `…-ROADMAP-epic-{slug}/`, seeds intent from the matching jam
brief (else validates the intake paste), writes `round-0-intent.md` + `prompt.md`. `/roadmap wave-N` (W) snapshots the wave skeleton to `round-0-intent.md`.
Hook sets `track:"roadmap"`, `current_phase:"round-loop"`, `initiated_by:"roadmap"`. Lock is two-step:
`locked.md` + canonical destination, then a one-screen diff confirmation, then state-file removal.

**Hook notes.** There is no phase-machine auto-advance for roadmap; `round-loop` is a pure per-turn inject
loop and **autonomous completion is behavioral** — the orchestrator runs the funnel, finalizes the canonical
artifact, and removes the state file within its own turn. `require-protocol.sh` `round-loop)` allows
advisor-tier; `roadmap)` blocks implementer-tier. (`--attended` runs halt at the round boundary instead of
finalizing — same wiring, behavioral contract read from `prompt.md`.)

---

## /planner — repo-aware planning partner (ADR-032; resolution tier ADR-033)

Configures the session as the operator's planning partner: drafts planning artifacts as files, reads the
repo natively (verify-by-view is the default), checks CC halts against ADR-018, routes into planning skills
(`/research`, `/roadmap`, `feature-decomposition`, `adr`, `@cto-advisor`, …). The full behavioral contract
(file-first output, observed behaviors a–h, halt-checking discipline) is in `core/agents/planner.md`,
injected each turn via `core/config/phases/planner/planner-loop.md`.

**Operating contract.** A persistent advisory partner; runs continuously; halts ONLY on the five ADR-018
criteria (1 architecture / 2 scope / 3 security / 4 operator-authority / 5 genuine ambiguity). Difficulty,
"checking in", and re-confirmation are not halts.

**Authorities granted (beyond shared).** Read anything in the repo. Write planning artifacts to `docs/**`,
`core/rules/**`, and the planner run folder. Route into advisor-tier skills.

**Authorities NOT granted (beyond shared).** Edit application source code — refused **even under `/bypass`**
(see the role-purity invariant). Run mutating shell commands — Bash is gated to a read-only allowlist by the
write-hook. To make a source change: draft it as text for the operator to paste, or recommend `/nimble` /
`/bypass`.

**Bypass overlay — the role-purity invariant (binding; diverges from adhoc/roadmap).** When `/bypass` is
also active, bypass lifts protocol *gating* (all agents pass). **But the planner write-hook
(`block-source-edits-planner.sh`) still refuses source edits — it has no bypass short-circuit, by design.**
Bypass governs *gating*; planner-mode governs *role-scoped tool surface* — orthogonal primitives. To write
source, **exit planner mode**; do not bypass through it. Do NOT add a bypass short-circuit to the planner
write-hook — its absence IS the contract (ADR-032).

**Hook short-circuits.** `workflow-state-inject.sh` `/planner*` writes `pending-initiation` with
`initiated_by:"planner"`; injects `phases/planner/planner-loop.md` every turn (inject-only).
`require-track-selection.sh` is unchanged — the `track:"planner"` active-run state file satisfies the gate,
so bare prompts flow without `/bypass` (resolves BL-015). `require-protocol.sh` `planner-loop)` allows
advisor-tier; `planner)` blocks implementer-tier. `block-source-edits-planner.sh` (default-deny +
allow-list `docs/**`, `core/rules/**`; Bash read-only allowlist) fires only when planner mode is active and
has **no bypass short-circuit**.

**State lifecycle.** `/planner [slug]` creates `docs/step-5-pipeline/YYYY-MM-DD/HHmm-PLANNER-{slug}/`, writes
`prompt.md`. PostToolUse hook detects `*-PLANNER-*` and creates the state file with `track:"planner"`,
`current_phase:"planner-loop"`, `initiated_by:"planner"`. Resume reads the latest artifacts and continues.

**Scope (v1).** Operator-driven track + write-hook + this contract. Deferred (ADR-032): porting claude.ai
planning skills into `core/skills/planner/`, the behavioral test suite, and v2/v3 agent-callable detection.

**Jam convergence is owned by `/sweep` (ADR-112 Wave 3 — re-homed).** The `/planner jam` sub-mode is RETIRED
(PEC-T9); jam clustering + convergence now live in `/sweep`'s in-skill convergence door, NOT in planner mode.
The binding **jam convergence contract** ("a jam converges by pruning into a single thesis doc that RESOLVES
its forks; an unresolved fork is an unfinished jam, not a build-time decision; every reconvergence pass updates
the machine-readable plan-vitality line `<!-- vitality: absorbed=N passes=N last=YYYY-MM-DD pending=N -->`")
now lives at its single source of truth in `core/skills/sweep/SKILL.md` § "Jam convergence" — it is NOT
re-authored here. Plain `/planner [slug]` is unchanged; it no longer carries a jam sub-mode. (ADR-049 records
the original `/planner jam` design; ADR-112 Wave 3 records the move to `/sweep`.)
