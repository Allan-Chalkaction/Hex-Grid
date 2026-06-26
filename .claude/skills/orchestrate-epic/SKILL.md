---
name: orchestrate-epic
description: "Build a whole multi-wave epic by INTERLEAVING plan + build per wave (roadmap wave N → build wave N → roadmap wave N+1 grounded on built N → …) on a shared epic branch (ADR-059). Use for taking a multi-wave epic from roadmap to integrated."
user_invocable: true
---

# /orchestrate-epic — interleaved plan+build of a whole epic (ADR-059)

`/orchestrate-epic <epic-slug>` is the **opt-in interleave** door for building a multi-wave epic. **It is NOT
the default epic build** — the default is `/orchestrated <epic-folder>`, which builds **all waves straight**
(front-loaded, in dependency order, in one run; ADR-112 Wave 2). Reach for `/orchestrate-epic` *only* when you
want each wave re-planned and built on the prior waves' *built* reality. It takes the epic from its roadmap to
an integrated epic branch by **interleaving** planning and building, **one wave at a time**:

```
roadmap wave 1 → build wave 1 → roadmap wave 2 (grounded on BUILT wave 1) → build wave 2 → …
```

The win is grounding: each wave's spec (its `spec-decomposer` slice, its Explore pass) is authored against the
**real, integrated code the prior wave just produced** — not just the prior wave's spec. It is **glue, not a
third engine** (like `/launch`): it sequences the existing `roadmap.js` (Phase W) and `orchestrated.js` per
wave on a shared **epic branch**, where git sequencing gives every wave the prior waves' built result for free
(both for planning grounding and the build base — the inter-wave analog of the intra-wave re-root, ADR-045/T16).

**Full contract + rationale:** `docs/decisions/ADR-059-interleaved-epic-build.md`.

This is distinct from:
- `/orchestrated <wave>` — builds ONE planned wave (this skill calls it per wave).
- `/roadmap` Phase E fan-out (ADR-058) — plans ALL waves up front from skeletons (plan-only; grounds on specs, not built code).
- `/launch` — fires *independent* waves in *parallel*; an epic's waves are *dependent* and *sequential*.

## Usage

- `/orchestrate-epic <epic-slug>` — interleaved plan+build of every wave in the epic's roadmap, in build order.
- `/orchestrate-epic <epic-slug> --use-existing-specs` — trust a pre-authored wave spec (e.g. from a prior `/roadmap` fan-out) as-is instead of re-planning it just-in-time. Faster; loses built-reality grounding for late waves.
- `/orchestrate-epic <epic-slug> --resume` — continue an interrupted epic build (default behavior on re-invoke too).

## Pre-flight

1. **The roadmap must exist.** Require `docs/step-3-specs/<epic-slug>/roadmap.md`. If absent → STOP: "No roadmap for `<epic-slug>`. Run `/roadmap` (Phase E) first." Do NOT author it here — this skill builds, it does not plan the epic shape.
2. **Resolve the wave build-order** from the roadmap (its build-order table / the ordered wave list). Each wave has a kebab `wave-slug`.
3. **Epic branch** (ADR-013, one level up):
   ```bash
   SLUG="<epic-slug>"; EPIC_BRANCH="feature/epic-$SLUG"
   git checkout -b "$EPIC_BRANCH" 2>/dev/null || git checkout "$EPIC_BRANCH"
   ```
   Every wave plans + builds off `$EPIC_BRANCH` HEAD; **main is never written during the run.**

## The interleaved loop (orchestrator-driven)

For each `WAVE` in build order, **skipping already-complete waves** (resume — see below), do:

### Step A — PLAN the wave just-in-time (roadmap Phase W)

Grounded on the **current `$EPIC_BRANCH` HEAD**, which already holds the built prior waves.

- Skip if `--use-existing-specs` AND `docs/step-3-specs/<epic>/waves/<wave>/<wave>.md` already exists.
- Else scaffold a roadmap-W run folder (per `core/skills/roadmap/SKILL.md` Phase W: `round-0-intent.md` = the wave's fat skeleton from the roadmap; `prompt.md`), then dispatch the roadmap Workflow:
  ```json
  { "runDir": "<run>", "repoRoot": "<abs>", "phase": "W", "epicSlug": "<epic>", "waveSlug": "<wave>",
    "intent": "<wave skeleton>", "attended": false }
  ```
  Resolve `scriptPath` per ADR-031 (`.claude/scripts/workflows/roadmap.js` else `core/...`).
- **Persist** the return (`persist-run-artifacts.py`) — writes `docs/step-3-specs/<epic>/waves/<wave>/{<wave>.md,-prompts.md}`, schema-checked.
- **Halt** if the roadmap-W return has `surfaceRequired:true` (an ADR-018 interrupt) — surface once, stop the epic loop; `/orchestrate-epic <epic> --resume` re-enters at this wave.

### Step B — BUILD the wave (orchestrated)

Off the **current `$EPIC_BRANCH` HEAD** (built prior waves are the base — the inter-wave re-root).

- Drive `/orchestrated` for `<wave>` per `core/skills/orchestrated/SKILL.md` (the wave branch is created off `$EPIC_BRANCH` HEAD, not main): its full chain (cto → architect-pre → pm-spec → [ui-spec] → [decompose] → explore → implement → integrate → batch-gate → architect-final), or its `2′` dependency-level loop for a deep wave. The just-authored `docs/step-3-specs/<epic>/waves/<wave>/` spec is the build input (its `# Wave:` schema → `tickets[]`).
- **Halt** on any `surfaceRequired` / short-circuit from the build (ADR-018) — surface once, stop; resume re-enters at this wave's build.
- On success, **merge the wave branch into `$EPIC_BRANCH`** so the next wave plans + builds on top of it:
  ```bash
  git checkout "$EPIC_BRANCH" && git merge --no-ff "feature/wave-<wave>" -m "epic($SLUG): integrate wave <wave>"
  git branch -d "feature/wave-<wave>"      # wave branch consumed into the epic branch
  ```

### Step C — next wave

`$EPIC_BRANCH` HEAD now contains `<wave>`. Continue with the next wave (back to Step A) — its plan + build see the just-integrated wave.

## Completion

When every wave is planned + built + merged into `$EPIC_BRANCH`:
- Present the epic completion report: each wave's spec path + build status + integrated SHAs.
- The **operator** opens the epic→main PR (operator-only, ADR-013 — never auto-merged). Per `rules-git.md` wave-branch hygiene applied one level up: verify `$EPIC_BRANCH` is on origin before `gh pr create`; the operator merges + deletes the epic branch.

## Resume (substrate-derived — no new manifest primitive for v1)

A wave is **planned** iff `docs/step-3-specs/<epic>/waves/<wave>/<wave>.md` exists; **built** iff its integration commit is on `$EPIC_BRANCH` (grep the epic-branch log for `integrate wave <wave>`). On `--resume` (or re-invoke), walk the build-order and resume at the first wave that is not both planned and built. Already-complete waves are skipped; a partially-done wave (planned, not built) resumes at Step B.

## Halts (the only stops — ADR-018 / ADR-029)

Autonomous to the epic-end package by default. The only interrupts are the five ADR-018 criteria, raised by any wave's plan funnel (Step A) or build (Step B). A `surfaceRequired` from either engine halts the **epic loop** (downstream waves depend on this one — never skip ahead), surfaces once (ADR-036 consolidated surface), and resume continues at the halted wave after the operator resolves it. Difficulty / "checking in" / a wave taking a while are NOT interrupts.

## Authorities

- **MAY:** create + commit on `$EPIC_BRANCH` and per-wave branches; merge each wave branch into `$EPIC_BRANCH`; dispatch the roadmap + orchestrated engines per wave; halt-and-resume across sessions.
- **MUST NOT:** write main during the run; open/merge the epic→main PR (operator-only); force-push; skip a halted wave; auto-resolve an ADR-018 surface.

## When NOT to use it

- A single wave → `/orchestrated <wave>`.
- Plan-only (no build) → `/roadmap` (Phase E fan-out plans all waves).
- Independent parallel waves → `/launch`.
