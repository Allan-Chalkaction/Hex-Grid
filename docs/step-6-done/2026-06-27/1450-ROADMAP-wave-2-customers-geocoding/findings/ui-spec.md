# ui-spec

_Persisted by the orchestrator from the roadmap workflow return (FLAG-1: scripts have no FS access; agents cannot Write)._

UI Specification Addendum written to: /Users/allanmittelstaedt/Desktop/Dev/hex-grid/docs/step-5-pipeline/2026-06-27/1450-ROADMAP-wave-2-customers-geocoding/ui-spec-addendum.md

## Key finding: the project is plain-CSS, not Tailwind
hex-grid has NO Tailwind, NO component library, and NO design-token (`--`) system. The design language is hand-authored semantic CSS in `src/index.css` (`.app-shell`, `.app-header`, `.site-panel`, `.site-list`, `.auth-gate`, `.field`, `.form-error`), a `rem`-based 0.25rem spacing rhythm, the system-ui font stack, and exactly two non-grey color literals: `#1a73e8` (interactive/focus blue) and `#b00020` (error red). I set **Token Mode = plain-css** and adapted every section to that reality — the agent template's Tailwind/shadcn examples do not apply and the addendum explicitly forbids them for this wave.

## New Wave 2 UI surfaces specced (with concrete visual + error-state UX)
- **S1** Add-customer panel/dialog — customer (brand) fields + repeatable site sub-form (customer-first flow recommended, geocode per site, consistent with the BINDING domain model)
- **S2** Per-site geocode status — pending / geocoded / failed
- **S3** Bulk import (CSV/SQLite) — file picker → parse → batch geocode → dedup → persist
- **S4** Import results/errors report — per-row outcome table
- **S5** Edit / move / delete with destructive-confirm
- **S6** Site pins on the deck.gl map overlay (replaces the current empty placeholder layer)

## Error-state UX (the requested emphasis — §5)
- Four **distinct, non-collapsed** geocode failures, each with its own recovery path: no-match (edit/manual coords), ambiguous (pick-a-candidate), network/timeout (retry), rate-limit/429 (auto-backoff + manual retry).
- Failed sites persist **un-geocoded and flagged** — never silently dropped.
- Bulk import: pre-upload client validation (size/type/row caps) BEFORE any network call (security gate), precise parse/column errors, in-flight `<progress>` + cancel, visible dedup feedback, and a results/errors report that **always renders even on total failure** with a copy/download-errors affordance.
- All status signaling is non-color-alone (word + glyph + color), carrying forward the W1 a11y contract (`useId()` label association, `role="alert"`, `aria-live`, native focus order, global `:focus-visible`).

## Contrast verification (all pass WCAG AA on the ~white panel)
near-black text ~17:1; `#b00020` error ~7.4:1; `#555` helper (additive) ~7.5:1; `#1a73e8` focus outline/UI ~3.9:1 (PASS at 3:1). Flagged: `#1a73e8` as normal-weight body LINK text is borderline (~3.9:1) — specified darkening to `#1558b0` (~5.9:1) for that one use.

## Reference patterns (in-repo north stars)
`AuthGate.tsx` (form + error pattern), `SiteList.tsx` (async LoadState + empty-state), `index.css` `.site-panel`/`.field`/`.form-error`, `MapShell.tsx` (pin layer attach point). No external library north star — the bar is consistency with these four W1 files.

## Deviation log highlights (gaps the design funnel should close)
- Form/flow shape was open → recommended customer-first + repeatable site sub-form (architect/pm-spec to confirm).
- Introduced one additive neutral `#555` for helper text (verified AA/AAA).
- File-size/row caps unspecified → flagged as required pre-upload validation; exact numbers to be set at design.
- Dialog vs panel unspecified → recommended native `<dialog>` (focus trap + ESC + backdrop) with `.site-panel`-style fallback.

Advisory only — no source files modified. Note: this ran inside a `/roadmap` Phase-W funnel, so the run_dir is the ROADMAP folder; the addendum should travel with the wave spec at `docs/step-3-specs/hex-grid/waves/customers-geocoding/` when the wave graduates.
