---
name: shape
description: The Altitude-1 disposition door - a driven, attended interview that triages + shapes accumulated step-1-ideas captures ONE AT A TIME (halts to riff each item, 1-30 questions), folds the riffed outcome back into the file, coarse theme-tags it, and disposes it (git mv into a bucket). Complements /sweep's Altitude-2 across-item convergence; carries NO convergence of its own. Triggers - "/shape", "shape this", "shape the inbox", "interview these captures", "shape needs-shaping".
user_invocable: true
---

# /shape — the Altitude-1 per-item disposition door

`/shape <folder-or-file>` is the **Altitude-1 disposition door**: a driven, **attended/interactive**
interview that walks accumulated captures ONE AT A TIME, riffs each with the operator, folds the riffed
outcome back into the item's file, coarse-tags it, and disposes it. It is the sibling of `/sweep`'s
**Altitude-2 convergence** — and it is a **NEW command, NOT a flag on `/sweep`** (ADR-119 D1). The
interview loop lives ONLY here; `/sweep` carries zero interview-loop implementation.

> **Two altitudes, two doors.**
> - **`/sweep` (Altitude-2)** clusters + converges *across* items into a single thesis — fine convergence.
> - **`/shape` (Altitude-1)** riffs *one item at a time* with the operator, folds the result back into
>   that item, and applies a **coarse** theme-tag — it NEVER clusters or composes theses.
>
> `/shape` does the per-item shaping `/sweep`'s W3 readiness check *recommends routing to* (ADR-117 D1).
> The readiness check points here; the interview body lives here, full stop. If `/shape` ever starts
> clustering or composing theses, it has crossed the altitude boundary — that is the failure mode (ADR-119
> Catches).

**Attended is the point.** `/shape` is a *driven* door that **HALTS to riff each item**. It is NOT an
autonomous batch pass — the halts ARE the feature (the inverse of engine-path autonomy). The operator is in
the loop for every item.

## Usage

- `/shape <folder>` — walk every not-yet-shaped capture in the folder, one at a time (the common case;
  `<folder>` is a `step-1-ideas` bucket — see § v1 scope).
- `/shape <file>` — shape a single capture file.
- Resume `/shape <folder>` — pick up where a prior session left off; already-shaped items are skipped
  by presence-of-section (see § Stateless resume).

## On invocation

1. **Resolve the scope** to the not-yet-shaped captures (§ Stateless resume computes the skip set).
2. For each not-yet-shaped item, run **the per-item loop** below — **in order, every step** — halting to
   riff. One item fully shaped + disposed before the next begins.
3. When the scope is exhausted, summarize: items shaped, where each was disposed (which bucket / jam),
   and any left un-shaped (operator stopped early). Stage-only — the operator reviews `git status` and
   commits.

## The per-item loop (each step explicit, in order)

Run these seven steps **in order** for every item. Steps 3–4 are where the door **HALTS** to interview the
operator. Step 5 (fold-back) is **MANDATORY** — see its callout.

### 1. seed-with-link
Open the item and **link it** so the operator can read the source directly. Surface the file path as a
clickable reference and pull the gist into view. The operator must be able to read the raw capture before
the interview starts — do not summarize from memory without the source on the table.

### 2. plain-English summary
Restate the item in clear prose: what it is, what it's asking for, what's ambiguous or under-specified.
Plain English, not a re-quote — the goal is a shared, legible read of the capture before the questions.

### 3. pose questions — **HALT here (attended)**
Pose **1–30 questions** to the operator about the item: scope, intent, the forks it leaves open, what
"done" looks like, where it should land. This step **HALTS to riff** — it is attended/interactive, NOT an
autonomous batch pass. The halt is the feature: the operator answers inline, the door waits. Number of
questions scales with the item's depth (a one-line stub may need 2–3; a meaty proposal may need 20+).

### 4. riff
Collaborative back-and-forth with the operator on the answers — follow-ups, pushback, alternatives,
sharpening. This is the shaping conversation. Continue until the item is understood well enough to be
acted on.

### 5. fold the outcome back into the file — **NON-NEGOTIABLE and MANDATORY**

> **REQUIRED. NOT OPTIONAL. This step MUST happen for every item.**
>
> Write the riffed outcome **back into the item's own file**. The natural carrier is a `## Shaped`
> section appended to the file capturing: the sharpened thesis, the decisions made in the riff, the forks
> resolved, and what "done" looks like. **An item is NOT shaped until this section is written.** Skipping
> the fold-back loses the entire value of the interview — the conversation evaporates and the next session
> re-litigates the same item from scratch.
>
> The fold-back is also the **stateless-resume signal** (§ Stateless resume): the presence of the
> `## Shaped` section IS the durable record that this item has been shaped. No `## Shaped` section ⇒ the
> item is not shaped ⇒ resume picks it up again. This is why the fold-back is non-negotiable — it is both
> the value-capture AND the state.

Use an Edit/Write that **appends** the `## Shaped` section — never clobber the original capture body.

### 6. coarse theme-tag — **COARSE only**
Apply a **COARSE theme-tag** — a broad topical label (e.g. `theme: engine`, `theme: inbox-conveyor`,
`theme: gating`). This is a single coarse bucket tag, recorded in the `## Shaped` section.

> **The boundary is real, not flavor text (ADR-119 Catches).** Fine convergence — drawing per-member
> cluster boundaries, composing a thesis *across* items, deciding "item A belongs with items 4 and 7" —
> stays **`/sweep`'s** job (its in-skill convergence pass). `/shape` applies ONE coarse tag to ONE item
> and stops. If `/shape` starts clustering items together or composing a cross-item thesis, it has
> crossed the altitude line into `/sweep`'s territory — that is the failure mode. Coarse tag, single item,
> no clustering.

### 7. disposition — surface ALL vectors, THEN move
Surface **ALL disposition vectors** to the operator (promote to a bucket, ingest into a jam, defer, drop,
keep, …), let the operator pick, **THEN** perform the `git mv` + any file rewrite. The disposition *rules*
that govern WHERE the move targets are encoded in § Disposition rules below (W6B). This step establishes
that disposition is the loop's terminal step: surface vectors → operator picks → stage the `git mv`.

## Stateless resume (presence-of-section — NO external state)

An item is **"shaped"** once it **carries a `## Shaped` section** OR **has left `needs-shaping/`** (its new
bucket is the proof it was disposed). Resume skips already-shaped items by **presence-of-section** — there
is **NO external state file, NO manifest, NO JSON** tracking progress.

- To compute the skip set on `/shape <folder>`: for each `*.md` in scope, an item is **already-shaped** iff
  `grep -q '^## Shaped' <file>` succeeds OR the item no longer lives in `needs-shaping/` (it was disposed).
  Everything else is **not-yet-shaped** and gets the interview.
- This mirrors the repo's **location-is-status** philosophy (ADR-087): the durable signal is the artifact
  itself (the `## Shaped` section / the item's bucket), never a side-car state file. The **absence of
  external state IS the contract** — do NOT introduce a JSON state file or a manifest to track which items
  are shaped.
- Resume is therefore free: re-running `/shape <folder>` picks up exactly the un-shaped remainder, in any
  session, with no resume manifest to read or write.

```bash
# skip-set computation (presence-of-section) — no state file
for f in docs/step-1-ideas/needs-shaping/*.md; do
  grep -q '^## Shaped' "$f" && continue   # already shaped — skip
  echo "$f"                               # not-yet-shaped — interview this one
done
```

## Disposition rules

The disposition step (loop step 7) obeys four dogfood-exposed rules. All four are binding constraints on
WHERE a disposition writes — surface the vectors, then `git mv` to a target that satisfies these rules.

### Rule 1 — Bucket never root
A disposition write goes into a **bucket** (the ADR-111 inbox taxonomy: `needs-shaping/`, `ready-to-build/`,
`backlog/`, `parked/`, `chores/`, `blocked-on-dependency/`, …), **NEVER the flat `docs/step-1-ideas/` root**.
No disposition write may target the flat inbox root — the root is a funnel, not a resting place. Every
disposition `git mv` target is `docs/step-1-ideas/<bucket>/...` or a planning/spec folder, never the bare
flat root.

### Rule 2 — Jam-related → `ingest-to-jam` (incl. phase-2-deferred)
A **jam-related** outcome folds into the jam via `ingest-to-jam` — `git mv` into the converging jam at
`docs/step-2-planning/jam-<cluster>/`. This **INCLUDES a phase-2-deferred outcome**: an item deferred to a
*later phase* of an in-flight jam folds into **the jam's later-phase lane** (the `## Later-phase scope`
entry in the jam's thesis — the ADR-117 D5 sibling), it is **NOT shelved as a re-fork**.

> **The phase-2-deferred path is the subtle one (ADR-119 Catches).** Dogfooding showed a
> phase-2-deferred-linked-to-a-jam outcome getting mis-shelved as a re-fork. The correct behavior is
> `ingest-to-jam` into the jam's later-phase lane — a phase-2-deferred item still **folds into the jam**,
> it does not become a new fork or get shelved out of the jam. (Same conceptual bug as the W3 G1 fix in
> `/sweep`, different door.) Be explicit: **phase-2-deferred ⇒ folds into the jam**, never re-forked.

### Rule 3 — `git mv`, not `cp`
Disposition moves use **`git mv`, NEVER `cp`** — history travels with the file and the **source leaves**.
A `cp` duplicates the capture and leaves the original in place, defeating the inbox-shrinkage signal. (This
also satisfies the epic-wide **stage-only** floor, ADR-105: `git mv` stages, it does not commit/push.)

### Rule 4 — Consumer-path aware (ADR-031)
Any shelled tooling `/shape` runs resolves **`.claude/scripts` first, else `core/scripts`** — `/shape` must
run on a **consumer repo**, not just inside claude-infra. Apply this to every core-script shell-out:

```bash
# ADR-031 substrate path resolution: .claude/scripts in a consumer, core/scripts in claude-infra.
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
python3 "$S/docs-index.py"     # regenerate docs/INDEX.md after disposition moves
```

## Stage-only verbs (ADR-105)

`/shape` uses **`git mv` / `git add` only** — NEVER `git commit`, `git push`, or `git reset --hard` in any
path it automates. Nothing reaches main/remote unattended. The operator reviews `git status` and commits.

## v1 scope = `step-1-ideas` buckets ONLY (Out-of-Scope forward reference)

**`/shape` v1 operates on `docs/step-1-ideas/` buckets ONLY** (the default `<folder>` is a step-1-ideas
bucket — typically `needs-shaping/`). The expansive ambitions are explicitly **OUT OF SCOPE** for v1 and
captured as a **forward reference**, NOT built (cto SIMPLIFY — a net-new foundational primitive is built
deliberately at a narrow boundary, not folded into a hardening epic at full ambition):

- **Out of scope — "any folder."** `/shape` does NOT operate on arbitrary folders in v1. Resist the
  near-free expansion to "any folder" — it is explicitly deferred (see
  `docs/step-1-ideas/DEFER-shape-any-folder-and-roadmap-basis.md`).
- **Out of scope — "becomes the basis for how `/roadmap` is run."** The ambition that `/shape` becomes the
  upstream basis for `/roadmap` is a forward reference, NOT built in v1.

These ambitions are recorded in `docs/step-1-ideas/DEFER-shape-any-folder-and-roadmap-basis.md`. A separate
door *linked to* `/sweep` is a **recommendation**, not an embedded coupling — `/shape` stays a standalone
attended door `/sweep` recommends routing to (ADR-117 D1), never an embedded part of `/sweep`.

## Guardrails

- **Attended, never autonomous.** `/shape` halts to riff every item — it is NOT a batch pass.
- **Fold-back is mandatory.** No item is shaped without its `## Shaped` section written back.
- **Coarse tag only.** `/shape` applies one coarse theme-tag per item; fine convergence is `/sweep`'s job.
- **No external state.** Resume is presence-of-`## Shaped`-section — no JSON, no manifest (ADR-087).
- **Bucket never root.** Every disposition write targets a bucket, never the flat inbox root.
- **`git mv`, not `cp`.** Stage-only (ADR-105); consumer-path aware (ADR-031).
- **v1 = step-1-ideas buckets only.** "Any folder" / roadmap-basis are deferred forward references.

## Notes

- See `docs/decisions/ADR-119-w6-shape-interview-command.md` (the wave ADR — the per-item loop + the v1
  boundary), `core/skills/sweep/SKILL.md` (the Altitude-2 sibling + the ADR-117 D1 readiness check that
  recommends this door), `core/skills/defer/SKILL.md` (the capture-at-bucket sibling),
  `docs/decisions/ADR-111-*` (the inbox bucket taxonomy), `docs/decisions/ADR-117-*` (the later-phase lane),
  `docs/decisions/ADR-087-doc-lifecycle-location-is-status.md` (location-is-status / stateless resume),
  `docs/decisions/ADR-031-*` (consumer script-path resolution), `docs/decisions/ADR-105-*` (stage-only).
