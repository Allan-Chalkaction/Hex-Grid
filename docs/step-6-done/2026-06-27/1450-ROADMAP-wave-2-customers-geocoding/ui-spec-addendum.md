# UI Specification Addendum: Wave 2 — customers-geocoding

**Feature:** customers-geocoding
**Date:** 2026-06-27
**Spec:** docs/step-3-specs/hex-grid/waves/customers-geocoding/customers-geocoding.md
**Intent:** docs/step-5-pipeline/2026-06-27/1450-ROADMAP-wave-2-customers-geocoding/round-0-intent.md
**Token Mode:** plain-css (hand-authored CSS in `src/index.css`; NO Tailwind, NO component library, NO `--`-prefixed token system)

> **Token vocabulary — READ FIRST.** This project does **not** use Tailwind and has **no** design-token
> system. The default agent template's Tailwind utilities and shadcn-style primitives **do not apply** and
> must NOT appear in the implementation. The design language is:
> - **Layout/visual:** hand-authored semantic CSS classes in `src/index.css`
>   (`.app-shell`, `.app-header`, `.site-panel`, `.site-list`, `.auth-gate`, `.field`, `.form-error`).
> - **Spacing:** `rem` values on a **0.25rem (4px) rhythm** (`0.25 / 0.5 / 0.6 / 1 / 1.5 / 3 / 4 rem`).
> - **Color literals (the only two non-greyscale values in the codebase):**
>   `#1a73e8` (focus/interactive blue), `#b00020` (error red). Greys: `#ddd` (borders),
>   `rgba(255,255,255,0.92–0.95)` (panel surfaces over the map).
> - **Type:** system-ui stack, `rem`-scaled (`1rem` base, `1.1rem` panel headings, `1.5` line-height).
>
> New Wave 2 surfaces MUST extend this vocabulary — add new semantic classes to `src/index.css` in the
> same style, reuse `.field` / `.form-error` / panel conventions, and use **native HTML elements**
> (`<form>`, `<input>`, `<select>`, `<button>`, `<table>`, `<progress>`, optionally `<dialog>`). Do not
> introduce a CSS framework or a component library for this wave.

---

## 0. New UI surfaces this wave introduces

Geography lives on `site`, not `customer` (BINDING domain clarification). The recommended flow shape is
**customer-first, then one-or-more sites**, with geocoding running **per site**. The new surfaces:

| # | Surface | Where it lives |
|---|---------|----------------|
| S1 | **Add-customer panel/dialog** — customer (brand) fields + a repeatable site sub-form | Triggered from the site panel header; rendered as an in-shell panel or `<dialog>` |
| S2 | **Per-site geocode status** — pending / geocoded / failed (with manual-coords fallback) | Inline within each site row of S1 and in the edit surface |
| S3 | **Bulk import** — file picker (CSV / SQLite) → parse → batch-geocode → dedup → persist | Separate panel/dialog opened from the site panel |
| S4 | **Import results/errors report** — per-row outcome table (created / matched / geocoded / failed) | Shown after S3 completes |
| S5 | **Edit / move / delete** — edit customer + site, move (re-geocode or drag), delete with confirm | Row actions on the existing/extended site list |
| S6 | **Site pins on the map** — deck.gl layer rendering persisted site `geog` points | The `MapShell` deck.gl overlay (currently an empty placeholder layer) |

The existing `SiteList` (`src/components/SiteList.tsx`) is the anchor — it should grow into a
customer→sites view (sites grouped under their customer brand) with row actions, reusing the `.site-panel`
surface.

---

## 1. Component Selection (native-element mapping)

There are no library primitives; map each element to a native element + a new semantic class.

- **Panels / dialogs (S1, S3):** prefer `<dialog>` (native, focus-trapping, ESC-to-close, `::backdrop`)
  OR an in-shell panel mirroring `.site-panel`. New class `.entity-panel` (same surface treatment:
  `rgba(255,255,255,0.95)`, `1px solid #ddd`, `border-radius: 8px`). If a dialog is impractical, reuse the
  `.site-panel` absolute-overlay pattern.
- **Forms (S1, S5):** `<form noValidate>` + `.field` blocks (label-over-input, `gap: 0.25rem`) exactly as
  `AuthGate`. Each input gets an associated `<label htmlFor>` via `useId()` (the W1 pattern — do not break it).
- **Repeatable site sub-form (S1):** a list of `.field`-grouped site blocks with an "Add another site"
  `<button type="button">` and a per-block "Remove" button. Each block: name + address inputs + the S2
  geocode-status line.
- **File picker (S3):** native `<input type="file" accept=".csv,.sqlite,.db">` wrapped in a `.field`.
  Show selected filename + size as plain text after selection (screen-reader readable).
- **Progress (S3):** native `<progress>` for batch-geocode progress, paired with a plain-text
  "Geocoding 12 of 40…" line inside an `aria-live="polite"` region (count is not conveyed by the bar alone).
- **Results table (S4):** native `<table>` with a `<caption>`, `<thead>` scope-correct `<th>`s, one row per
  imported row. New class `.import-results`.
- **Row actions (S5):** native `<button type="button">` per action (Edit / Move / Delete). No icon-only
  buttons without an accessible name — if iconographic, add `aria-label`.
- **Map pins (S6):** deck.gl `ScatterplotLayer` (or `IconLayer`) on the existing `MapboxOverlay`. Not DOM —
  styled via layer props, see §4.

---

## 2. Layout & Spacing

Follow the existing `rem` rhythm — do NOT introduce an 8px-grid Tailwind scale; match what `index.css`
already uses.

| Element | Spacing |
|---------|---------|
| Panel/dialog inner padding | `0.5rem 1rem` (matches `.site-panel` / `.app-header`) |
| `.field` vertical gap (label→input) | `gap: 0.25rem` |
| Between `.field` blocks | `margin-bottom: 1rem` (matches `.auth-gate .field`) |
| Site sub-form block separation (S1) | `1rem` gap + a `1px solid #ddd` divider between site blocks |
| Input padding | `0.5rem` |
| Primary button padding | `0.6rem` (matches `AuthGate` submit) |
| Secondary/row-action button padding | `0.25rem 0.5rem` |
| Results table cell padding (S4) | `0.25rem 0.5rem` |
| Panel max-width (dialog form) | `~24rem` for a single-column form; `~40rem` for the results table |
| Panel max-height + overflow | `max-height: 70vh; overflow: auto` (matches `.site-panel`) |

Rules: stay on the `0.25rem` step; no arbitrary px values; one padding scale per surface type (don't mix
`0.5rem` and `0.6rem` inner padding on the same panel).

---

## 3. Typography Hierarchy

System-ui stack, `rem`-scaled. There is no font-weight token system; use literal `400 / 600 / 700`.

| Role | Size | Weight | Notes |
|------|------|--------|-------|
| Dialog/panel title (S1/S3) | `1.1rem` | `600` | Matches `.site-list h2` scale; use a real `<h2>`/`<h1>` |
| Section sub-heading ("Sites", "Import results") | `1.1rem` | `600` | `<h2>`/`<h3>` |
| Field label | `1rem` | `400` | `<label>` |
| Input text | `1rem` | `400` | Matches `.auth-gate input` |
| Body / helper text | `1rem` (or `0.9rem` for dense helper) | `400` | Plain `<p>` / `<span>` |
| Geocode-status text (S2) | `0.9rem` | `400` normal / `600` on error | See §5 |
| Error text | `1rem` | `600` | `.form-error` (`#b00020`) |
| Table data (S4) | `0.9rem` | `400` | header `<th>` `600` |
| Monospace (raw coords, address hash, row index) | `0.9rem` | `400` | `font-family: ui-monospace, monospace` |

Do not drop below `0.85rem` for any text the user must read. Line-height stays at the `:root` `1.5`.

---

## 4. Color Usage (literal values — this project has NO tokens)

Every value below already exists in `src/index.css` or is a minimal additive neutral. Do NOT add new
brand hues without operator sign-off.

**Surfaces (over the map):**
- Panel/dialog background: `rgba(255,255,255,0.95)` (matches `.site-panel`).
- Header strip: `rgba(255,255,255,0.92)` (matches `.app-header`).
- `<dialog>::backdrop` (if used): `rgba(0,0,0,0.4)`.

**Borders/dividers:** `#ddd` (the only border grey in the codebase). Table row dividers: `1px solid #ddd`.

**Text:**
- Primary text: inherit (near-black system default on white).
- Helper/secondary text: `#555` (additive — verify 7:1 on white; `#555` ≈ 7.5:1, passes AA + AAA).
- Error text: `#b00020` (≈ 7.4:1 on white — passes AA; always paired with weight `600` + a non-color cue).
- Interactive/links: `#1a73e8`.

**Geocode-status semantics (S2/S4) — never color-alone (WCAG 1.4.1):** pair every status with a text label
and/or glyph, not just a hue:
- Pending: `#555` text + "Geocoding…" + a spinner/`aria-busy`.
- Success: a checkmark glyph + "Geocoded" text; optional `#1a7f37` green (verify ≈ 4.9:1 on white — passes
  AA) but the **word** carries the meaning.
- Failed: `#b00020` + a warning glyph + "Couldn't geocode" text + the failure reason.

**Map pins (S6) — deck.gl layer props (not WCAG-text, but keep distinguishable):**
- Default site pin fill: `#1a73e8` (RGBA `[26,115,232,230]`), radius scaled with zoom.
- Hovered/selected pin: a larger radius + a `#ffffff` stroke (`getLineColor [255,255,255]`,
  `lineWidthMinPixels: 2`) so it reads against varied basemap tiles.
- Un-geocoded sites are NOT pins — they surface only in the list with the S2 "failed/pending" state.
- Pin color must not be the sole carrier of meaning; selection state also drives the list highlight.

**Contrast verification (all text pairings on the `rgba(255,255,255,0.9x)` panel ≈ white):**
| Pair | Ratio | AA? |
|------|-------|-----|
| near-black text / white panel | ~17:1 | PASS |
| `#b00020` error / white | ~7.4:1 | PASS |
| `#555` helper / white | ~7.5:1 | PASS |
| `#1a73e8` link text / white | ~3.9:1 | PASS for large/bold + UI focus (3:1); for normal-size body link, bold it or darken to `#1558b0` (~5.9:1) |
| `#1a73e8` focus outline (non-text) / white | ~3.9:1 | PASS (UI ≥ 3:1) |

> If `#1a73e8` is used for **normal-weight body-size link text**, darken to `#1558b0` (≈ 5.9:1). The focus
> outline use (existing `:focus-visible`) is fine as-is.

---

## 5. Interactive States & Error-State UX (the load-bearing section)

Carry forward the W1 a11y contract verbatim: native focus order, `:focus-visible` outline
(`2px solid #1a73e8`, already global), label association, `role="alert"` for errors, `aria-live` for async
status, errors never color-alone, real `<button>`s, disabled-while-submitting.

### Buttons
- Hover: subtle darken (e.g. `filter: brightness(0.95)` or a `:hover` background shift) — keep it real but
  light; no library variants exist.
- Focus: rely on the global `:focus-visible` outline. Do not remove it.
- Disabled (in-flight): `disabled` attribute + `cursor: not-allowed` + reduced opacity (`0.6`); swap label
  to a progress verb ("Importing…", "Geocoding…", "Saving…") — the `AuthGate` "Signing in…" pattern.

### S1 Add-customer / per-site geocode (S2)
- On submit: disable submit, show per-site inline status in an `aria-live="polite"` region.
- **Geocode pending:** "Geocoding {address}…" in `#555`, `aria-busy="true"` on the row.
- **Geocode success:** checkmark + "Geocoded" + the resolved lat/lng in monospace; the row's pin appears on
  the map.
- **Geocode failure — distinct, recoverable states (do NOT collapse into one generic error):**
  | Failure | Message | Recovery affordance |
  |---------|---------|--------------------|
  | No match (Census returned 0) | "No match for this address." | Edit-address inline OR "Enter coordinates manually" (lat/lng `.field`s) |
  | Ambiguous (multiple candidates) | "Multiple matches — pick one:" | A `<select>`/radio list of candidates |
  | Network / timeout | "Geocoding service didn't respond." | "Retry" button (single-row retry) |
  | Rate-limited (Census 429) | "Too many requests — retrying shortly." | Auto-backoff + a manual "Retry now" |
  - Each failure: `#b00020` text, weight `600`, a warning glyph, `role="alert"` on first appearance. The
    customer + already-geocoded sites still persist — a failed site is saved **un-geocoded** (no silent data
    loss), flagged in the list for later fix.

### S3 Bulk import — error-state UX
- **Pre-upload validation (surface BEFORE any network call):** reject by `role="alert"`:
  file too large (state the cap, e.g. "Max 5 MB"), unsupported type, empty file, row count over cap.
- **Parse errors:** if the CSV/SQLite can't be parsed, show a single clear error + which row/column failed;
  do NOT start geocoding a partially-parsed file.
- **Column mapping:** if headers don't match expected (`customer`, `name`, `address`…), show a mapping step
  or a precise "Missing required column: address" message — never a generic "invalid file".
- **In-flight:** `<progress>` + `aria-live` "Geocoding N of M…"; a "Cancel" button that halts the batch and
  keeps already-persisted rows.
- **Dedup feedback:** when a row matches an existing customer (by name within tenant) or an existing site,
  the results report marks it "Matched existing" / "Skipped duplicate" — visibly, not silently.

### S4 Import results/errors report (must always render, even on total failure)
- A `<table class="import-results">` with a `<caption>` summarizing counts:
  "40 rows — 36 imported, 2 failed, 2 duplicates."
- Columns: row #, customer (created/matched), site name, address, **status** (Created / Matched / Failed /
  Duplicate), reason (for failures).
- Status cells use the §4 non-color-alone semantics (word + glyph + color).
- Provide a **"Copy errors" / "Download error rows"** affordance so the user can fix and re-import only the
  failures — do not make them hunt.
- A summary `role="status"` line announces the outcome for screen readers.

### S5 Edit / Move / Delete
- **Delete:** native confirm step (`<dialog>` or inline "Delete {name}? This removes its N sites." with
  Confirm/Cancel). Destructive button visually distinct (`#b00020` text or border) — never auto-confirm.
- **Move:** editing a site's address re-runs geocoding through the same S2 status flow (cache makes
  re-geocode of an unchanged address free).
- Optimistic update is acceptable but on failure roll back + `role="alert"`.

---

## 6. Reference Patterns (in-repo north stars)

The implementer should mirror these existing files — they already encode the project's quality bar:

- `src/components/AuthGate.tsx` — **the form + error pattern to copy**: `useId()` label association,
  `.field` blocks, `role="alert" aria-live="assertive"` errors, disabled-while-submitting with a progress
  verb, native `<form noValidate>`. S1 and S5 forms should look like this.
- `src/components/SiteList.tsx` — **the async load-state pattern**: discriminated `LoadState`
  (`loading | error | ready`), `role="alert"` on error, plain-text counts for screen readers, empty-state
  copy ("No sites yet."). S4 and the extended list should reuse this exact shape.
- `src/index.css` `.site-panel` / `.field` / `.form-error` — the surface, field, and error-text vocabulary
  to extend (don't reinvent).
- `src/components/MapShell.tsx` — where the S6 pin layer attaches (replace the empty placeholder
  `MapboxOverlay({ layers: [] })` with the site layer).

No external library north star applies — the bar is "consistent with the four W1 components above."

---

## 7. Anti-Patterns (Do NOT do — project-specific)

- Do **NOT** introduce Tailwind, shadcn/ui, Material, or any component library for this wave. Plain CSS only.
- Do **NOT** reference Tailwind utility classes or `--`-prefixed tokens — none exist; they will not resolve.
- Do **NOT** signal geocode/import status by color alone — always pair with a word + glyph (WCAG 1.4.1).
- Do **NOT** collapse the distinct geocode failures (no-match / ambiguous / network / rate-limit) into one
  generic "Geocoding failed" — each has a different recovery path (§5).
- Do **NOT** silently drop a site that failed to geocode — persist it un-geocoded and flag it.
- Do **NOT** skip the results/errors report when an import partially or fully fails — it must always render.
- Do **NOT** remove or override the global `:focus-visible` outline.
- Do **NOT** add icon-only buttons without an `aria-label`.
- Do **NOT** start geocoding before client-side file validation (size/type/rows) passes (security gate).
- Do **NOT** expose raw service/stack errors in the UI (project security rule) — map to user-facing copy.

---

## Deviation Log

| Area | What was missing | Default applied |
|------|-----------------|----------------|
| Token system | Agent template assumes Tailwind + a component library; project has neither | Set Token Mode = `plain-css`; mapped every section to the existing `src/index.css` class vocabulary + native elements |
| Form/flow shape | Intent left "customer-first vs single combined form" open | Recommended **customer-first + repeatable site sub-form**, geocode per site (consistent with the BINDING domain model); flagged as the architect/pm-spec decision |
| Helper-text grey | No neutral grey for secondary text in the codebase | Introduced `#555` (verified ≈ 7.5:1 AA/AAA) — minimal additive neutral, no new hue |
| Link-text contrast | `#1a73e8` passes for focus/UI but is borderline (~3.9:1) for normal-weight body link text | Specified darken to `#1558b0` (~5.9:1) when used as body-size link text |
| Pin styling | Intent says "see them as pins" with no visual spec | Proposed deck.gl `ScatterplotLayer`, `#1a73e8` fill + white stroke on hover/select; un-geocoded sites excluded from the layer |
| File-size / row caps | Not specified; security-auditor gate covers upload | Flagged as a required pre-upload validation with explicit caps; exact numbers (e.g. 5 MB) to be set at design |
| Dialog vs panel | Not specified | Recommended native `<dialog>` (focus trap + ESC + backdrop) with `.site-panel`-style fallback |
