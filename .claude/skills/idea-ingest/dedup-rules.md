# /idea-ingest — slugification + dedup classification rules

<!-- Support doc for /idea-ingest. (Briefly lived under core/skills/bulk-jam/ when ADR-081 merged idea-ingest
     into /bulk-jam --ingest; ADR-112 split capture back out to the standalone /idea-ingest door.) -->


The dedup primitive is **skill-local**: it reads the **set of existing `docs/step-1-ideas/*.md` filenames** and
classifies each segmentation candidate against them. No helper script, no shell-out — these rules ARE the
primitive.

## Slugification (matches `/idea` step 2c verbatim)

A candidate's identifier is normalized the same way `/idea` computes its filename slug
(`core/skills/idea/SKILL.md` step 2c): **lowercased, non-alphanumerics → `-`, collapsed, trimmed** (and
~6 words). Apply this to the candidate's `short_slug` before matching.

## The existing slug fragment

Each existing backlog file is named `<YYYY-MM-DD>-<slug>.md` (ADR-087: no `RAW-` prefix; `DEFER-`/`FOLLOWUP-`
files carry a kind tag before the date). The **slug fragment** is the `<slug>` part — strip any kind tag and
the `<YYYY-MM-DD>-` date. Compare against the **filename set** (the slug fragments), never against file *bodies*.

> **Architect correction (do not drop this):** this is **not** `bulk-jam-plan.py:110`'s primitive. That line
> (`new = [s for s in shorts if s not in text]`) substring-matches a short-slug against a single jam dir's
> **concatenated body text**. Here the target is a **filename set** — a different shape. Same family of idea
> (substring/exact dedup), different target; do not re-cite line 110 as identical.

## Three-way classification

Let `c` = the slugified candidate, and `{f}` = the set of existing slug fragments.

| Label | Derivation |
|---|---|
| **DUPLICATE** | `c` **exactly equals** some `f` (already captured — skip). |
| **NEAR-DUPLICATE** | exact-match ruled out AND `c` is a **substring of** some `f`, **or** some `f` is a substring of `c` (a match in *either* direction). |
| **NEW** | neither exact nor substring against any `f` (a genuinely-new spark — eligible to write). |

## Worked examples

Existing fragments: `transcript-ingest-skill`, `verify-shipped-gate`, `graduate-jam-script`.

| Candidate (slugified) | Result | Why |
|---|---|---|
| `transcript-ingest-skill` | **DUPLICATE** | exact match. |
| `transcript-ingest` | **NEAR-DUPLICATE** | substring of `transcript-ingest-skill`. |
| `verify-shipped-gate-explore-path` | **NEAR-DUPLICATE** | `verify-shipped-gate` is a substring of it. |
| `idea-ingest-dry-run-preview` | **NEW** | no exact or substring match against any fragment. |

## What the labels drive (at the review gate)

- **DUPLICATE** → skipped automatically (reported, not written).
- **NEW** → written via `/idea` **only on operator confirmation**.
- **NEAR-DUPLICATE** → **never auto-merged**; the operator decides **skip** / **write-anyway** per candidate.
  Near-duplicate *semantics* are delegated downstream to `/sweep`'s in-skill convergence (ADR-112 Wave 3;
  the smart-cluster gate moved there from the retired `/idea-jam --cluster-only`) — capture stays dumb.
