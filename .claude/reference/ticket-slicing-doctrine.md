# Ticket-slicing doctrine (one source — cite, don't copy)

> **Status:** Binding reference (ADR-044, amended by ADR-062). This is the **single** home for how work is
> sliced into tickets. `spec-decomposer` (the slicer brain), the `feature-decomposition` skill, and
> `/roadmap` Phase W's `pm-spec` all **cite** this doc; none restate it. A ticket born in any door is the
> same object, sliced to the same quality. *Edit here once — every door inherits it.*

A **ticket** is `{ key, description, depends_on[] (ticket keys), planned_files[], acceptance[] (the AC-NNN
atoms it claims), wave_slug?, gates? }` (ADR-044). The rules below govern how the spec's work is grouped into
tickets, with the **within-wave vs cross-wave split** (ADR-062) calling out which legacy rules apply where.

## 1. Group by implementation dependency

Cluster work into tickets by what must be built together as a coherent unit. Consider:
- **Data dependencies** — migrations before the code that uses the schema.
- **Component boundaries** — one component per ticket (unless trivially small).
- **Integration points** — wire-up / integration is a separate ticket from creation.
- **Verification boundaries** — each ticket must be independently verifiable (typecheck, test).

**No artificial limits on ticket count.** One ticket or fifty — whatever the spec requires. A migration is
typically one ticket; a complex component might be one or several.

**`planned_files` — within-wave vs cross-wave (ADR-048, amended by ADR-062).** The legacy "no shared write
target across parallel tickets" rule was scoped to the ADR-040 parallel-per-ticket build model. ADR-062
moves parallelism up to the wave/`/launch` level — so the rule splits along the same seam:

- **Within a wave (ADR-062 §3):** there is **one sequential writer** (one implementer building all in-wave
  tickets in one context). Shared `planned_files` across in-wave tickets is **fine** — it collapses to an
  **ordering hint for the writer** (the writer applies the changes in `depends_on` order). No within-wave
  merge contention is possible. **Do not add `depends_on` edges purely to satisfy a within-wave shared sink**
  (that was the ADR-040 model's requirement; under ADR-062 it just narrows what's still genuinely
  parallel at the right level).
- **Across waves (`/launch` parallel waves, ADR-053):** the legacy rule still binds. **No shared write
  target across PARALLEL waves**: two cross-wave tickets that may run in parallel (no `depends_on` edge,
  no wave-level dependency) MUST NOT name the same file — parallel waves merge at integrate, and a shared
  sink (`styles.css`, a barrel `index.ts`, one router config, one migrations file) collides at the
  cross-wave merge even when the content each adds is itself disjoint.

When two cross-wave tickets name the **same file** (a *shared sink*), do ONE of:
- **(default) Serialize via `depends_on`** when the sink is an **append target** — give the later ticket a
  `depends_on` edge to the earlier; the cross-wave merge proceeds in order, no contention.
- **Set `coupling_hint: "high"`** only when the tickets must genuinely **co-edit** the same region (not a
  clean append) — the wave planner won't parallelize them across waves.

A shared write target left between two cross-wave *parallel* tickets is a slicing error (the decomposer's
Step-4 verification catches it). Within a wave the decomposer no longer flags shared sinks (ADR-062
dissolves the within-wave hazard).

## 2. Coherence test (apply per candidate ticket)

A ticket must produce one of:
1. Standalone observable runtime behavior — exercisable by a user, a test, or another component.
2. A testable contract meaningful in isolation — a new function with its unit test; a grep test extended to
   catch a new violation class.
3. A consolidated verification artifact (see §3).

A candidate **fails** if its only verification is "a downstream ticket can use this" or "typecheck passes"
with no behavior change. **Failed candidates fold into their consuming ticket in the same wave.** If the
consumer is in a future wave, the candidate stays solo.

- *Stays solo:* "Wire 9 IPC handler bodies" — one integration point (single dispatch contract).
- *Stays solo:* "Extend license-tier grep test" — testable contract in isolation.
- *Folds:* "Add `@radix-ui/react-roving-focus`" → into the component that consumes it (the dep alone does nothing).
- *Folds:* "Add a `--color-border-success` CSS token" → into the first component that reads it (a token nobody reads is dead code).
- *Folds:* "Wire preload bridge namespace" → into the IPC-handlers ticket (resolves a typecheck error, no runtime behavior).

**Folding boundary:** the consumer absorbs trivial prerequisites freely, capped at one component or one
cohesive integration point. Past that boundary, split the consumer first; the trivial then folds into a split.

## 3. Verification consolidation

When multiple candidate tickets would each verify a different shipped module from the **same family** — same
test-command pattern, same ADR section family, same service domain, or same test-fixture surface — emit ONE
consolidated verification ticket producing a single artifact. Its findings MUST enumerate per-module verdicts
independently (one named section per module); a gap in any one module surfaces as its own GAP, never buried in
the aggregate. It MUST NOT expand its own scope mid-execution — unexpected gaps surface as a gap finding and
route to a follow-up ticket.

**Does NOT apply when verification surfaces genuinely diverge:** different test runners (Playwright vs.
Vitest), different runtimes (browser vs. Node), unrelated ADR sections, or unrelated service domains.

## 4. Ordering & dependencies

Foundational work (migrations, types, shared utilities) precedes consumer work (components, integration).
`depends_on` lists the **keys** of the tickets a ticket directly depends on (`[]` for a leaf). The graph
must be acyclic with no forward/self/orphan references.

**The meaning of `depends_on` splits along the wave seam (ADR-062 / ADR-045 amended):**

- **Within a wave: sequencing hint for one writer.** One implementer builds all in-wave tickets sequentially
  in one context, so `depends_on` orders the writer's pass over the ticket list — "do T-001 before T-002 in
  the wave-build prompt." It does **not** drive a parallel-merge contract, and ADR-045's per-ticket
  concurrency cap is moot within a wave (there is no within-wave parallel dispatch). Within-wave
  `depends_on` is OPTIONAL where ordering is obvious from the prompt itself; add edges where they aid the
  writer's understanding of the build order.

- **Across waves: parallel-merge contract.** Wave-level dependencies (wave N depends on wave N-1's
  *integrated* result, e.g. the `/orchestrate-epic` interleave case, ADR-059) AND cross-wave ticket
  dependencies under `/launch` (ADR-053 parallel waves) retain the legacy semantics: `depends_on` is
  load-bearing for graph validation, cross-wave integrate-time merge order, and any cross-wave parallelism
  the planner can extract. A missing cross-wave edge causes a real merge collision.

## 5. Atom coverage (traceability without a matrix)

Each ticket tags the `AC-NNN` atoms it claims in `acceptance[]` (ADR-044/047). The traceability guarantee is a
one-pass set check: **the union of all tickets' `acceptance[]` equals the spec's `AC-NNN` set** — an unclaimed
AC is a "we dropped something" gap. No separate traceability matrix, `atom_count`, or phantom-atom audit is
needed (those v1 mechanisms are retired — ADR-047).
