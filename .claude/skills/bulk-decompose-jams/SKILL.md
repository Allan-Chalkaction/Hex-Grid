---
name: bulk-decompose-jams
description: Decompose every operator-flagged (`decompose: ready`) jam into paste-ready ticket prompts in one driven pass, halting for review between jams (--auto runs straight through). Readiness is operator-declared, not guessed. Triggers - "/bulk-decompose-jams", "bulk decompose the jams", "decompose all the ready jams", "graduate jams to builds".
user_invocable: true
---

# /bulk-decompose-jams — decompose every build-ready jam, jam by jam

`/bulk-decompose-jams` is to **decomposition** what `/sweep` is to **convergence**: it walks every jam
in `docs/step-2-planning/jam-*/`, and for each one **you have promoted** (`- **decompose:** ready` in its brief) it
runs the planning funnel (`@cto-advisor → @architect-review → [@ui-spec] → slice`) and writes **paste-ready
ticket prompts** — **halting for review between jams** so you stay in control. It is a **thin wrapper**: the
readiness/upsert plan lives in `bulk-decompose-plan.py`; the slicing judgment lives in
`core/reference/ticket-slicing-doctrine.md`. This skill only sequences them.

> **Readiness is DECLARED, not inferred (load-bearing).** "Is this jam ready to decompose?" is an *operator*
> judgment — *"only when I say yes."* The plan does NOT guess readiness from prose labels (an earlier rev did;
> it misfired and eroded trust). It reads exactly two unambiguous things: your explicit `decompose: ready`
> flag, and whether a `decomposition/` folder already exists (idempotency). Unflagged jams are simply "not
> promoted yet" and are skipped silently. To promote a jam, stamp `- **decompose:** ready` in its brief
> (`skip` = nothing to build; `hold` = not ready / converge first).

Pipeline context: `/idea (or /idea-ingest to capture from a discussion) → /sweep (triage + converge into jams) →`
**`/bulk-decompose-jams` (decompose + graduate)** `→ docs/step-3-specs/<slug>/ (build queue) → /orchestrated | /launch | /bypass (build)`.
Decomposing **graduates** the jam: its folder MOVES from `docs/step-2-planning/jam-<slug>/` to `docs/step-3-specs/<slug>/`
(move-on-advance, ADR-051), which is what "ready to build" means — see "Graduate to the build queue" below.

> **Why a skill, not "run roadmap on each jam".** `/roadmap` halts every round for operator tuning and exits
> only on operator *lock* — so sequencing roadmaps stalls at the first one and never reaches the next; it is
> attended by design. This skill is roadmap's funnel **minus the per-round tuning** — the deliberate trade of
> tuning fidelity for set-and-forget throughput. Reserve `/roadmap` for the one jam that genuinely needs
> round-by-round tuning. (Design rationale: the planner finding `bulk-decompose-jams-design.md`.)

## Usage

- `/bulk-decompose-jams` — decompose every READY/STALE jam, **pausing for review after each**.
- `/bulk-decompose-jams --auto` — run straight through with no per-jam halts (for when you trust convergence).
- `/bulk-decompose-jams --only <slug,slug>` — restrict to named jams (slugs without the `jam-` prefix).
- `/bulk-decompose-jams --target bypass|orchestrated` — output shape. **Default `bypass`** (paste-ready
  prompts). `orchestrated` emits the parseable `# Wave:` ticket schema instead (see roadmap Phase W's
  output-format contract).
- `/bulk-decompose-jams --no-graduate` — decompose in place only; do NOT move the jam to `docs/step-3-specs/`. By
  default an accepted decomposition **graduates** the jam (moves it to the build queue — see below).

## On invocation

Runs as the **bypass orchestrator** (writes `docs/step-2-planning/jam-*/decomposition/` directly; advisor agents stay
read-only — the orchestrator persists their findings). Requires bypass active (it dispatches `@`-agents and
writes decomposition artifacts); if bypass is off, ask the operator to `/bypass on` first.

1. **Compute the readiness plan** (read-only):
   ```bash
   python3 "$([ -d .claude/scripts ] && echo .claude || echo core)/scripts/bulk-decompose-plan.py"   # add --only slug,slug if given
   ```
   It reports each jam by its DECLARED state (no inference): **READY** (`decompose: ready`, no `decomposition/`
   yet) / **STALE** (`decompose: ready`, decomposed but the brief changed after) / **DONE** (`decomposition/`
   present and current) / **SKIP** (`decompose: skip` — operator: nothing to build) / **HOLD** (`decompose:
   hold` — operator: not ready / converge first) / **UNMARKED** (no flag — not promoted yet). Only **READY**
   and **STALE** are decomposed this pass.

2. **Surface the plan and the non-actionable buckets** before doing any work:
   - **UNMARKED** jams → name them once and note they're awaiting promotion (`decompose: ready`). Do NOT
     decompose them and do NOT nag — they're simply not promoted yet. If one looks ready, *suggest* the
     operator stamp it; never stamp it yourself.
   - **HOLD** jams → name them + their `decompose-note` reason (e.g. "converge via `/sweep` first").
   - **SKIP** / **DONE** → one-line acknowledgement; out of scope this pass.

3. **Decompose the READY/STALE set.** Two execution modes:

   **Default (review-gated, sequential — orchestrator-driven):** for each READY/STALE jam in plan order, run
   the **per-jam funnel** (below) yourself, then **HALT for review** after each jam — show that jam's ticket
   set + the prompt file paths + (for a STALE re-decompose) what changed; **end the turn**. On continue → next
   jam. This mode runs in your context, one jam at a time; it's right when you want to eyeball each before the
   next. The two hard halts (missing-ADR crit-1, scope-shift crit-2) stop the offending jam.

   **`--auto` (parallel, set-and-forget — Workflow fan-out):** instead of the sequential loop, dispatch ALL
   READY/STALE jams concurrently via the **`decompose-jams` Workflow** — the genuine "stick it on everything"
   path (parallel, engine concurrency-capped, zero per-turn context burn):
   1. Build the jams arg from the plan: `jams = [{ slug, jamDir, briefPath, note }]` (one per READY/STALE jam;
      `note` = the jam's `decompose-note` if any). Resolve `briefPath` to its `README.md` (or `index.md`).
   2. Invoke the **`Workflow`** tool with `scriptPath` = `.claude/scripts/workflows/decompose-jams.js` if that
      path exists, else `core/scripts/workflows/decompose-jams.js`, and `args` =
      `{ repoRoot: "<abs repo root>", target: "<bypass|orchestrated>", jams }`. The script fans the funnel
      (cto-advisor → architect-review → [ui-spec] → pm-spec) out per jam in independent pipeline branches.
   3. On completion the script **returns** `{ results: [{ slug, status, spec_md, prompts_md, ticket_count,
      scope_note, blockReason, findings }], blocked, scopeShift, surfaceRequired }` — it writes nothing
      (contract 2). For each `status:'decomposed'` result, **you persist** `spec_md` + `prompts_md` to
      `jam-<slug>/decomposition/` and `findings.*` to `jam-<slug>/findings/`.
   4. Present **one fan-in review** (not per-jam halts): the decomposed jams + their ticket counts + file paths,
      then the surfaced set — `blocked` jams (missing-ADR, crit-1) and `scopeShift` jams (crit-2) — for your
      decision. `--auto` skips the per-jam halts but NOT this single consolidated surface.

4. **Idempotency** (both modes): writing `jam-<slug>/decomposition/` flips that jam to DONE; a re-run only
   re-decomposes STALE jams (brief edited after). Never re-chews a current decomposition.

5. **Done** — print a one-line summary: decomposed N, blocked B, scope-shift S, skipped K, unmarked U.

## Per-jam funnel (the decomposition itself)

This is roadmap's Phase-W funnel without the tuning rounds. For one jam (`docs/step-2-planning/jam-<slug>/`):

1. **Read the whole jam** — the converged brief (`README.md`/`index.md`) and everything under the folder. The
   brief is the spec input; do not re-derive it.
2. **`@cto-advisor`** — strategic/feasibility gate on the converged brief. Persist → `jam-<slug>/findings/cto-advisor.md`.
3. **`@architect-review`** — architectural soundness, ADR needs, and the foundational ticket-boundary cut.
   Persist → `jam-<slug>/findings/architect-review.md`.
   **HARD HALT (ADR-018 crit-1):** if architect surfaces a genuinely new architectural decision with **no
   governing ADR**, stop this jam — flag it for `/roadmap` or an `/adr` pass and move on. **Fires even under
   `--auto`.** Never decompose against a missing ADR (the `feature-decomposition` "when to refuse" rule).
4. **`@ui-spec`** — only if the jam has a non-trivial UI surface. Persist → `jam-<slug>/findings/ui-spec.md`.
   (Skip silently for non-UI jams.)
5. **Slice + author prompts** — apply `core/reference/ticket-slicing-doctrine.md` (the same doctrine
   `spec-decomposer` and roadmap's pm-spec use): vertical slices, ≤ ~10 files each, observable acceptance in
   3–5 bullets, disjoint `planned_files` across parallel tickets, direct `depends_on` edges. Emit per `--target`:
   - **`bypass` (default):** paste-ready ticket prompts in the `bypass-mode-prompt-authoring` /
     `feature-decomposition` format (autonomy framing + the 4-tier halt protocol + per-ticket gate recos +
     `Isolation: worktree`).
   - **`orchestrated`:** the parseable `# Wave:` ticket schema (`### KEY: title` blocks with `depends_on` /
     `planned_files` / `gate_recommendations` / `manual_review_required` / a `description` block). Keys match
     `^[A-Z][A-Z0-9]*-[A-Z0-9]+$` (single hyphen). Verify it parses with `wave-manifest.py write-from-plan`.

   **HARD HALT (ADR-018 crit-2):** if the jam's scope is materially larger or different than its brief implies
   (a genuine scope shift, not just "more tickets than expected"), stop and surface it rather than inventing
   scope. Fires even under `--auto`.

### Output (idempotent upsert)

Per jam → `docs/step-2-planning/jam-<slug>/decomposition/`:
- `tickets.md` — wave grouping + dependency edges (roadmap-fragment shape) + per-ticket gate recos.
- `prompts.md` — one paste-ready prompt per ticket (in the `--target` format).
- `findings/` — the advisor outputs (already written in the funnel).

Re-running **overwrites in place** (upsert keyed on jam slug); it never forks a `-2`. STALE detection is by
mtime (brief newer than `decomposition/`), so a re-run only re-decomposes jams whose brief actually changed —
mirroring `bulk-jam-plan.py`'s no-ledger idempotency.

## Graduate to the build queue (move-on-advance — ADR-051)

A successfully-decomposed jam is **build-ready**, and "ready" is status-by-location: it MOVES out of
`docs/step-2-planning/` into the build queue `docs/step-3-specs/<slug>/`. This is the jam→spec boundary of the one
move-on-advance rule (ADR-051 §3) — the same primitive that relocates a jammed idea into `jam/source/`.

**When the move happens.** Default-on for an **accepted** decomposition:
- **Gated (default) mode:** after you review a jam and reply continue, that jam graduates (the continue is the
  acceptance gate). A `blocked` (crit-1) or `scope-shift` (crit-2) jam does NOT graduate — it stays in
  `docs/step-2-planning/` until resolved.
- **`--auto` mode:** every non-blocked, non-scope-shift jam graduates as part of the fan-in.
- **`--no-graduate`:** suppress the move; the jam stays in planning with `decomposition/` written in place
  (the old behavior — use when you want to eyeball more before committing it to the queue).

**The move (per accepted jam) — `graduate-jam.py` (ADR-061):**
```bash
SLUG="<jam slug without the jam- prefix>"
TARGET="<orchestrated | bypass>"
python3 core/scripts/graduate-jam.py --slug "$SLUG" --target "$TARGET"
```
`graduate-jam.py` does all three operations as one observable, testable step (replacing the hand-driven
snippet that used to live here — the documented source of drift this ADR-061 closes):
1. **Move** — `docs/step-2-planning/jam-$SLUG/` → `docs/step-3-specs/$SLUG/`, via `git mv` with a plain-`mv` fallback
   (mirroring the `/orchestrated` move precedent at `core/skills/orchestrated/SKILL.md:84,118`).
2. **Reshape (`--target orchestrated` only)** — each wave's `# Wave:` schema is reshaped into per-wave
   folders so `/launch` and `/orchestrated` can pick them up off the queue (they glob `docs/step-3-specs/*/waves/*/`):
   `# Wave:` body → `docs/step-3-specs/$SLUG/waves/<wave-slug>/<wave-slug>.md` and its prompts →
   `docs/step-3-specs/$SLUG/waves/<wave-slug>/<wave-slug>-prompts.md`; everything else from the jam (source/,
   findings/, brief) is retained at `docs/step-3-specs/$SLUG/` root.
3. **Intent-artifact handoff** — the converged brief (`README.md`, fallback `index.md`) rides along to the
   new home via the move, completing the forward direction of ADR-051 §8's intent handoff.

For `--target bypass`, the script is **move-only** (no `waves/` reshape) — the paste-ready prompts land at
`docs/step-3-specs/$SLUG/decomposition/prompts.md`, since bypass builds are driven by pasting prompts, not by the
wave-folder queue.

**Refuse-on-target-exists.** The script refuses (non-zero, no mutation) when `docs/step-3-specs/$SLUG/` already
exists non-empty — an already-graduated jam. To re-graduate, `git rm -rf docs/step-3-specs/$SLUG` first, then
re-run. This idempotency-via-refusal posture is the binding contract (ADR-061); never hand-merge over an
existing spec folder.

**Idempotency after graduation.** A graduated jam is gone from `docs/step-2-planning/jam-*/`, so `bulk-decompose-plan.py`
(which scans planning/) simply never re-sees it — the move IS the terminal "done" signal, superseding the
in-place DONE state. git is the history; nothing lingers in two places.

**Terminal jam-husk cleanup (deferred + idempotent) — `closeout-jam.py` (ADR-106/107).** After
graduation, the jam husk now lives at its post-graduation home `docs/step-3-specs/$SLUG/`. Once the spec
it produced **advances** (built-pending-merge or merged, per the ADR-107 stage model), the husk moves to
its terminal home `docs/step-6-done/jams/$SLUG/` (MOVE never DELETE — the husk holds the only tree copy of
`git-mv`'d-in source ideas). Wire this cleanup as a **deferred, idempotent** step in the graduation flow:

```bash
# Deferred + idempotent: NO-OPS until the produced spec has advanced (gated no-op). Safe to call right
# after graduation — it simply gates-out until advancement, then moves the husk on a later run.
python3 core/scripts/closeout-jam.py "$SLUG"
```

**Deferred/idempotent invocation contract:** `closeout-jam.py` is safe to invoke at graduation time AND
on every later sweep — it NO-OPS (gated) while the spec is still the live working copy, and only moves the
husk once the spec reaches built-pending-merge/merged. It is idempotent (an already-moved husk is a no-op)
and missing-source-tolerant. It STAGES only (`git mv`/`git add`, never commits/pushes). Because it gates
itself, you do not have to track "is the spec built yet?" — call it at graduation and let it defer.

## Guardrails

- **Reuse, don't duplicate.** Readiness/upsert logic lives in `bulk-decompose-plan.py`; slicing judgment in
  `core/reference/ticket-slicing-doctrine.md`; prompt format in `bypass-mode-prompt-authoring` /
  `feature-decomposition`. This skill only sequences them.
- **Sequential review gates by default.** Review each jam before the next; `--auto` is opt-in. Never decompose
  the whole backlog silently unless `--auto` is given — and `--auto` never overrides the two hard halts
  (missing-ADR crit-1, scope-shift crit-2).
- **Only the operator promotes.** Decompose a jam iff it carries `decompose: ready`. Never stamp readiness
  yourself and never decompose an UNMARKED/HOLD jam — if one looks ready, *suggest* the operator promote it.
  Quality of decomposition ∝ how converged the jam already is, and that judgment is the operator's.
- **Advisor agents stay read-only.** They return findings; the orchestrator persists them and authors the
  decomposition artifacts. No implementers are dispatched — decomposition is planning, not building.
- **Each step stays individually invokable** — `/sweep` (jam convergence), `@spec-decomposer`,
  `feature-decomposition`, `/roadmap` all still work alone; this is just the driven end-to-end decompose pass.
- Writes only `docs/step-2-planning/jam-*/decomposition/` (+ `findings/`) and, on graduation, **moves** the jam
  folder to `docs/step-3-specs/<slug>/` (move-on-advance, ADR-051). Both are `docs/**` (orchestrator-permitted). No
  source edits, no new state machine, no ledger.

## When NOT to use it

- **One jam that needs real tuning** → `/roadmap wave-N` (attended, round-by-round).
- **A jam that isn't converged yet** → `/sweep` (converge it in-skill via `ingest-to-jam`/`new-cluster`) first.
- **Building** the decomposed tickets (now graduated to `docs/step-3-specs/<slug>/`) → `/bypass` (paste the prompts
  from `docs/step-3-specs/<slug>/decomposition/`) or `/orchestrated <wave-slug>` (for the `# Wave:` output under
  `docs/step-3-specs/<slug>/waves/<wave-slug>/`) or `/launch` (fleet-drains the wave folders off the queue).
