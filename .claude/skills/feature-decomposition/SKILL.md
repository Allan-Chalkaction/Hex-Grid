---
name: feature-decomposition
description: Decompose a feature into nimble-track tickets (wave grouping, dependency edges, gate recommendations, per-ticket prompt drafts). Use when the user mentions decomposing, slicing, chunking, or breaking down a feature for nimble runs, or asks how to structure a feature for /nimble. Do NOT use for foundational architectural decomposition (that's @architect-review) or work that doesn't go through the nimble track.
---

# Feature decomposition for nimble execution

Produce a decomposition plan that lets the user run `/nimble` against tight, independently-verifiable tickets. The output is a markdown artifact paste-ready for `docs/roadmap.md` plus prompt drafts paste-ready for individual /nimble run folders.

## Why this skill exists

The user's nimble track has no spec-decomposer, no auto-routed gates, and no in-flow architect. A feature pitched as "build user profiles" will produce one implementer turn that flounders trying to do data + API + UI + auth + tests in a single shot. The fix is a hand-rolled decomposition into vertical slices that each fit in one implementer turn and have observable acceptance criteria. This skill encodes the discipline.

## Output format

Always produce these sections in this order. They go into a single markdown file delivered via `present_files` (the user's project instructions require file-first delivery for substantive artifacts).

### 1. Pre-decomposition checks

Before any tickets, surface three things:

- **@cto-advisor recommendation:** yes/no with a one-line rationale. Always propose; the user decides whether to actually invoke. The user has explicitly opted into "always propose" — don't skip this even when the feature seems strategically obvious.
- **Required ADRs / @architect-review invocations:** any cross-cutting decision (new data model territory, new auth flow, new integration boundary, performance-critical path) that needs an ADR before tickets can be written. If any are missing, **stop here** — propose them and wait. Don't write tickets against missing ADRs; the implementer has nothing to cite and will guess at architecture.
- **@ui-spec recommendation:** yes/no based on whether the feature has a non-trivial UI surface (more than a button-on-an-existing-page). If yes, the @ui-spec invocation should happen before the UI tickets, not as a post-hoc review.

If pre-decomposition checks pass, proceed.

### 2. Decomposition rationale (one paragraph)

Explain how you sliced the feature and why. Mention the natural seams — typically data → API → UI, or feature-flag boundaries, or independent capabilities. One paragraph, not an essay. The rationale exists so the user can sanity-check your seams before committing to the ticket list.

### 3. Roadmap fragment

A markdown block ready to paste into `docs/roadmap.md`:

```markdown
## Wave N — [Wave name] (parallel-safe within wave)
- [ ] APP-NNN  [Short title]
- [ ] APP-NNN  [Short title]

## Wave N+1 — [Wave name] (depends on Wave N)
- [ ] APP-NNN  [Short title] (depends on APP-NNN)
```

Use the project's ticket prefix (default `APP-`) and continue from the highest existing ticket number. If you don't know the high-water mark, ask before guessing — getting ticket numbers wrong creates real downstream confusion.

### 4. Per-ticket prompt drafts

One markdown block per ticket, in the format defined by the `nimble-prompt-authoring` skill. If `nimble-prompt-authoring` is available, follow its format exactly. If not, the format is:

```
[TICKET-KEY]: [Short title]

Per ADR-XXX ([topic]), [relevant constraint].

Acceptance:
- [3–5 verifiable bullets]

Gates (post-implementation):
- @[agent-name] — [reason]

Isolation: worktree
```

### 5. Open questions

Anything that blocks confident decomposition. Trim ruthlessly — only surface questions that genuinely block the plan. Vague curiosity about implementation details belongs in the ticket itself for the implementer to figure out.

## Slicing doctrine (single source — cite, don't restate)

Slice tickets per the binding **`core/reference/ticket-slicing-doctrine.md`** (ADR-044) — the single home for
the **coherence test** (fold a candidate whose only verification is "a downstream ticket can use this"),
**folding boundary**, **verification consolidation**, **sizing** (one vertical slice; ≤ ~10 files;
independently deployable; acceptance expressible in 3–5 bullets), and **ordering / disjoint `planned_files`**.
This skill does NOT duplicate those rules — read the doctrine and apply it. The doctrine doc is the same brain
`spec-decomposer` slices with, so a ticket drafted here and a ticket sliced in `/orchestrated` are shaped the
same way.

> **Routing note (ADR-044):** `spec-decomposer` is the single slicer *brain*. This planning skill is a *door*
> that produces paste-ready `/nimble` ticket drafts; it applies the same doctrine. (Invoking `spec-decomposer`
> directly from this skill — so the door literally calls the brain — is a behavioral follow-up; the doctrine
> unification is the durable win and is done here.)

## Wave grouping

Wave grouping follows the **wave-vs-cross-wave split (ADR-062)** the slicing doctrine encodes — read
`core/reference/ticket-slicing-doctrine.md` §1 (shared-sink) and §4 (`depends_on` semantics) for the full
contract; this section is the operator-facing summary.

- **Within a wave: tickets are sequential, not parallel.** One implementer builds all in-wave tickets in
  one context (ADR-062 §1). Within-wave `depends_on` is a **sequencing hint** for that single writer
  (apply T-001 before T-002 in the wave-build prompt), not a parallel-merge contract. Shared
  `planned_files` across in-wave tickets is fine — the single writer applies the changes in order. Bias
  toward as many tickets as aid spec clarity and AC-coverage; tickets within a wave are essentially free.
- **Across waves: dependencies are a parallel-merge contract.** Cross-wave `depends_on` is explicit
  (`depends on APP-NNN`) and **direct, not transitive**. If APP-007 depends on APP-006, and APP-006 already
  depends on APP-005, write `APP-007 (depends on APP-006)`. The transitive edge to APP-005 is implied;
  restating it is noise. Cross-wave shared sinks are real collision hazards under `/launch` parallel waves
  (ADR-053) — serialize via `depends_on` or `coupling_hint:"high"` per the doctrine.
- **Conservative wave split (ADR-062 §3):** open a new wave only when the work exceeds one implementer's
  context budget (the now-primary trigger), a hard cross-wave dependency requires building wave N+1
  against wave N's *integrated* result, or an integration/gate boundary must close first. Thematic
  distinctness or tidiness are **NOT** reasons for a new wave — the wave already *is* the fresh context.
  **Minimize waves; decompose into tickets liberally.**
- Foundation work (Phase A artifacts — ADRs, scaffolding, hello-world) is always Wave 0.
- A typical feature spans 1–3 waves under ADR-062 (the pre-ADR-062 "2–4 waves" guidance assumed the
  per-ticket parallel model that has since been retired).

### Dependencies: include the within-wave ordering edge

When in doubt about whether ticket B depends on ticket A **within the same wave**, include the edge as a
sequencing hint for the single writer — a missing in-wave edge only confuses the build order, not the
merge. **Across waves**, the cost asymmetry still favors inclusion: a missed cross-wave edge causes real
merge collisions under `/launch` parallel-waves dispatch; an over-specified edge only reduces wave-level
parallelism.

## Gate recommendations per ticket

Mark gates inside each ticket prompt based on what the ticket changes:

| Change shape | Pre-impl gate | Post-impl gate |
|---|---|---|
| New migration | (none) | @db-migration-reviewer (pre-apply, before merge) |
| Auth / RLS / session change | (none) | @security-auditor |
| User input / PII / external integration | (none) | @security-auditor |
| New UI surface | @ui-spec (must exist before the ticket) | @ui-review, @accessibility-auditor |
| Hot query / large payload / bundle-affecting | (none) | @performance-reviewer |
| Cross-cutting / new pattern | (none) | @code-reviewer (sooner than batch cadence) |

@code-reviewer batches every 3–5 tickets via `/batch-gate` by default. Only pull it forward for genuinely novel patterns where waiting for the batch would compound errors across multiple tickets.

## Worked example — "user profiles"

Bad ticket: "build profiles" — too big.

Bad decomposition:

```
APP-009  Add Profile TypeScript type
APP-010  Add profile slice to user store
APP-011  Profile schema + migration
APP-012  Profile read query
APP-013  Profile view page
APP-014  Profile edit form
APP-015  Avatar upload
```

Why this is bad: APP-009 and APP-010 fail the coherence test — typecheck-passes is not observable behavior. APP-011 and APP-012 are split where they shouldn't be — the migration's verification *is* "the read query works against it"; splitting them adds ceremony without value.

Good decomposition:

```
Wave 1 — Profile data layer
  APP-010  Profile schema + migration + read query

Wave 2 — Profile UI (depends on Wave 1)
  APP-011  Profile view page (read-only)
  APP-012  Profile edit form + server action
  APP-013  Avatar upload (depends on APP-012)
```

Each ticket: ≤10 files, one implementer turn, observable behavior, independently verifiable. APP-010 carries @db-migration-reviewer. APP-011/012 carry @ui-review + @accessibility-auditor. APP-012/013 carry @security-auditor (owner-only enforcement, file upload). All carry @code-reviewer via batch.

The Profile type? Folded into APP-010, where it's first defined and used.

## When to refuse

If the relevant ADRs don't exist (no data-model ADR for a feature that introduces entities; no auth ADR for a feature gated by roles), refuse to decompose. Propose the missing ADR work first via @architect-review. The user's project instructions explicitly back this up — decomposing against missing ADRs guarantees per-ticket drift.
