# UI Specification Addendum: Customers + Per-Site Geocoding (Wave 2)

**Feature:** customers-geocoding
**Date:** 2026-06-27
**Spec:** docs/step-5-pipeline/2026-06-27/1520-WAVE-customers-geocoding/spec.md
**ADR:** docs/decisions/ADR-002-customers-geocoding.md (per spec ADR alignment)
**Token Mode:** project-tokens (plain semantic CSS classes + literal hex in `src/index.css` — NOT Tailwind, NOT CSS custom properties)

> **Token vocabulary (binding for this repo).** This project uses **plain semantic
> CSS classes** in `src/index.css` with **literal hex values** (`#1a73e8`,
> `#b00020`, `#555`, `#ddd`). There is no Tailwind, no utility classes, and no
> CSS custom-property design-token layer. Do NOT introduce Tailwind utilities,
> `bg-*`/`text-*` classes, CSS variables, or arbitrary inline hex in TSX.
> Add new visual rules as **named semantic classes** in `src/index.css` and
> reference them by `className` — mirror the existing `.site-panel` / `.field` /
> `.form-error` conventions exactly. `MapShell` is the one documented exception
> that uses an inline `style` object (for the absolute-fill canvas) — do not
> extend that pattern to the new surfaces.

---

## 0. Visual Context (what this wave looks like)

W1 shipped a full-bleed MapLibre map (`MapShell`, absolute `inset:0`) with a
translucent top header (`.app-header`) and a single floating left panel
(`.site-panel`, `top:3rem; left:1rem; width:18rem`) containing the read-only
`SiteList`. There are **no cards, no data grid, no component library** — the
aesthetic is *minimal floating glass panels over a map*.

Wave 2 replaces `SiteList` with three new surfaces — `CustomerForm` (add),
`CustomerImport` (CSV), `CustomerList` (CRUD) — plus deck.gl pins on the map.
The visual job is to extend the existing floating-panel idiom to hold richer
forms and lists **without inventing a new design language**. Keep it spare,
keep panels translucent-white over the map, keep the existing spacing rhythm
(`0.25rem` / `0.5rem` / `1rem`).

---

## 1. Component Selection

There is no component library — everything is native HTML elements styled by
semantic classes. Build the new surfaces from native primitives, reusing the
W1 class vocabulary:

| UI element | What to render | Reuse / new |
|---|---|---|
| Panel container (each surface) | `<section className="site-panel ...">` or a sibling panel class | reuse `.site-panel` base; see §2 for multi-panel layout |
| Form fields (customer name, attrs, site address) | `<div className="field"><label htmlFor={id}>…</label><input/></div>` | reuse `.field` from AuthGate |
| Repeatable site rows (`CustomerForm`) | `<fieldset>` per row with `<legend>`, or a `.site-row` div list + "Add site" / "Remove" `<button>` | new `.site-row` class |
| Submit / action buttons | real `<button type="submit">` / `<button type="button">` | reuse bare button styling; add `.btn-secondary` only if a visual distinction is needed |
| Inline errors | `<p role="alert" aria-live="assertive" className="form-error">` | reuse `.form-error` |
| Per-site geocode status | `<span className="geo-status geo-status--{pending\|ok\|failed}">` with glyph + word | new `.geo-status*` classes (§6) |
| Customer/site list | `<ul>`/`<li>` grouping customers → nested sites (extend `.site-list`) | extend `.site-list` |
| Delete confirm / add dialog | native `<dialog>` (focus trap + ESC + backdrop free) — spec-recommended; `.site-panel`-style fallback acceptable | new `.confirm-dialog` class |
| CSV progress | real `<progress max value>` element | new `.import-progress` class |
| CSV cancel / copy-errors | real `<button>` | reuse button styling |
| Map pins | deck.gl `ScatterplotLayer` via `sitePinsLayer(sites)` mounted in `MapboxOverlay` | new `sitePinsLayer.ts` |

Do NOT pull in any UI dependency. The only new package this wave is `papaparse`
(CSV parsing, non-visual).

---

## 2. Layout & Spacing

Follow the existing rem-based rhythm in `src/index.css`. The repo's de-facto
spacing scale is **0.25rem / 0.5rem / 1rem** (4 / 8 / 16px) — stay on it. No
arbitrary one-off values.

**Multi-panel layout decision (under-specified by spec — see Deviation Log):**
W1 has one left panel. Wave 2 adds three surfaces. Recommended arrangement that
preserves the floating-panel idiom and keeps the map visible:

- Keep ONE left panel column (`.site-panel`) as the home for `CustomerList`
  (the persistent CRUD surface).
- Put `CustomerForm` and `CustomerImport` behind a native `<dialog>` opened from
  "Add customer" / "Import CSV" buttons in `.app-header` (or at the top of the
  list panel). This avoids stacking three wide panels over a small map and gives
  forms a focus-trapped, ESC-dismissable surface for free.
- If a dialog is not used, stack panels vertically in the left column with
  `gap: 1rem`; never exceed `width: 22rem` per panel (forms need a touch more
  room than the 18rem list).

| Element | Rule |
|---|---|
| Panel padding | `0.5rem 1rem` (match `.site-panel`) |
| Panel border-radius | `8px` (match `.site-panel`) |
| Panel border | `1px solid #ddd` (match) |
| Panel background | `rgba(255, 255, 255, 0.95)` (match `.site-panel`) |
| Form field gap (within `.field`) | `0.25rem` (label→input, match AuthGate) |
| Between fields | `margin-bottom: 1rem` (match `.field`) |
| Between site rows | `gap: 0.5rem` or `margin-bottom: 0.5rem` |
| Section gap (form ↔ site-list block) | `1rem` |
| Dialog padding | `1rem 1.25rem` |
| Dialog max-width | `28rem` (forms with repeatable rows need more width) |
| Dialog border-radius | `8px` (consistency) |
| Button padding | `0.5rem` – `0.6rem` (match AuthGate submit `0.6rem`) |
| Progress bar block | `margin: 0.5rem 0` |
| List item (`<li>`) vertical gap | `0.25rem` |

No `px` font sizing in new rules except where matching an existing rule; prefer
`rem`. No inline styles in TSX (the `MapShell` canvas is the sole exception).

---

## 3. Typography Hierarchy

The repo sets only `:root` font-family (system-ui stack) and `line-height: 1.5`.
Headings use browser defaults except `.site-list h2` (`font-size: 1.1rem`).
Keep the scale minimal and consistent with W1:

| Role | Element | Size | Weight | Color |
|---|---|---|---|---|
| Login title | `<h1>` (AuthGate only) | browser default | default | inherit (near-black) |
| Panel heading | `<h2>` in panels | `1.1rem` (match `.site-list h2`) | default (bold) | inherit |
| Sub-heading (customer name in list) | `<h3>` or `<strong>` | `1rem` | `600` | inherit |
| Body / list text | `<p>`, `<li>` | `1rem` (default) | `400` | inherit (near-black) |
| Field label | `<label>` | `1rem` (default) | `400` | inherit |
| Input text | `<input>` | `1rem` (match AuthGate input) | `400` | inherit |
| Muted / helper / count text | `<p>` helper | `0.875rem` | `400` | `#555` (≥7:1 on white — passes AA) |
| Geocode status word | `<span>` | `0.875rem` | `600` | per status (§6) |
| Error text | `.form-error` | `1rem` | `600` | `#b00020` (~7:1 — passes AA) |

Do not introduce a heavy type scale or large display sizes — these are dense
utility panels, not a marketing surface. `1rem` is the body baseline (this is a
desktop tool; the spec's "dashboard text-sm" guidance does not apply to this
plain-CSS, rem-based repo — keep `1rem` to match W1).

---

## 4. Color Token Usage

All colors are **literal hex in `src/index.css`**. The complete palette in use,
verified against the file:

| Purpose | Value | Where | Contrast on white |
|---|---|---|---|
| Focus outline (non-text UI) | `#1a73e8` | `:focus-visible` outline | ~3.6:1 — passes the **3:1 non-text** bar (AC-020: this is NOT body text; do not "fix" it) |
| Error text | `#b00020` | `.form-error` | ~7:1 — passes AA text |
| Muted text | `#555` | helper/count text | ~7.5:1 — passes AA text |
| Panel/header border | `#ddd` | `.site-panel`, `.app-header` | decorative border — no text bar |
| Panel surface | `rgba(255,255,255,0.95)` | `.site-panel` | base surface |
| Header surface | `rgba(255,255,255,0.92)` | `.app-header` | base surface |

**New colors this wave (all verified ≥ their required bar on the panel white background):**

| Purpose | Value | Contrast on white | Bar | Result |
|---|---|---|---|---|
| Body-text link (if any introduced) | `#1558b0` | ~5.9:1 | 4.5:1 text | PASS (AC-020 — use this, never `#1a73e8`, for a link rendered as body text) |
| Geocode "geocoded" status text | `#137333` | ~5.9:1 | 4.5:1 text | PASS |
| Geocode "failed" status text | `#b00020` (reuse) | ~7:1 | 4.5:1 text | PASS |
| Geocode "pending" status text | `#555` (reuse) | ~7.5:1 | 4.5:1 text | PASS |

**Surface layering** (lightest map → panel → text): map canvas (full color) →
translucent white panel (`rgba(255,255,255,0.95)`) → near-black body text →
muted `#555` for secondary text. There is no multi-tier gray surface system;
do not invent one.

**Map pin color (`sitePinsLayer`):** use a single saturated fill that reads on
the OpenFreeMap `liberty` (light) basemap. Recommend `#1558b0` fill (the same
AA-safe blue) at radius ~6–8px with a thin white stroke (`getLineColor` white,
`lineWidthMinPixels: 1`) for separation from light terrain. Pins are a non-text
map component — the 3:1 graphical-object bar applies and `#1558b0` clears it
comfortably. (If geocode-status differentiation on the map is wanted later, that
is out of scope this wave — all pins one color.)

---

## 5. Interactive States

The repo relies on the **global `:focus-visible` outline** (`2px solid #1a73e8`,
`outline-offset: 2px`) for all keyboard focus — every new interactive element
inherits it automatically. Do not remove or override it. Do not add a separate
focus style.

| Element | State | Spec |
|---|---|---|
| All focusable elements | focus (keyboard) | inherit global `:focus-visible` (2px `#1a73e8` outline, 2px offset) — already AA |
| Buttons | hover | `cursor: pointer` (match AuthGate); optional subtle `opacity: 0.9` or `background` shift — keep minimal |
| Buttons | disabled | `disabled` attribute + `cursor: not-allowed`; AuthGate uses label swap ("Signing in…") — mirror for in-flight submits ("Adding…", "Importing…") |
| Submit (form invalid / 0 sites) | blocked | disable submit OR show `role="alert"` error on attempt; AC-011 requires the ≥1-site guard to block submit |
| List item / site row | hover | optional `background: rgba(0,0,0,0.04)` for affordance — not required |
| Site row "Remove" button | default/hover | bare `<button>`; never remove the last row if it would drop below 1 site (disable when count === 1) |
| CSV cancel button | active during import | enabled only while import in-flight; cancelling stops further network calls (AC-014) |
| Dialog | open/close | native `<dialog>` ESC-to-close + backdrop; return focus to the trigger on close |
| Inputs | focus | global outline; no custom border-color change needed |

Every interactive element MUST be a real `<button>`/`<a>`/`<input>` — no
`<div onClick>` (AC-020 native-element requirement).

---

## 6. Status Indicator Patterns (geocode status — AC-012)

This wave has no "badges" in the component-library sense; the load-bearing
indicator is **per-site geocode status**, which MUST be non-color-alone (word +
glyph + color) and screen-reader readable.

Render as: `<span className="geo-status geo-status--X"><span aria-hidden="true">{glyph}</span> {word}</span>`
with the human word as real text (so a screen reader announces it; the glyph is
`aria-hidden`). Add `geo-status` classes to `src/index.css`.

| Status | Word | Glyph (aria-hidden) | Text color | Weight |
|---|---|---|---|---|
| Pending | "Pending" | `…` (or a CSS spinner) | `#555` | `600` |
| Geocoded | "Geocoded" | `✓` | `#137333` | `600` |
| Failed | "Failed" | `⚠` | `#b00020` | `600` |

Rules:
- Never signal status by color alone — the word is mandatory and is the SR text.
- A failed-geocode site is **persisted un-geocoded and visibly flagged** — never
  silently dropped (AC-012).
- For the four failure classes, render the specific recovery affordance inline
  next to the "Failed" status (AC-012):
  - **no-match** → "Enter coordinates manually" (manual lat/lng inputs)
  - **ambiguous** → "Pick a candidate" (candidate list)
  - **network-timeout** → "Retry" button
  - **rate-limit-429** → "Retry" button with backoff note ("retrying in Ns")
- The recovery control is a real `<button>` / `<input>`; it inherits the global
  focus outline.
- Status text uses `0.875rem` / `600` per §3.

No solid-colored badge backgrounds; status is colored **text + glyph + word**,
consistent with the repo's flat, borderless aesthetic.

---

## 7. CSV Import Surface (AC-013 / AC-014 / AC-019)

- **Progress:** a real `<progress max={total} value={done}>` element (class
  `.import-progress`, `margin: 0.5rem 0`, `width: 100%`). Pair with a text
  count ("Imported 42 of 1000") in `#555` so progress is SR-readable (native
  `<progress>` is announced, but a text fallback is cheap insurance).
- **Cancel:** real `<button type="button">Cancel</button>`, enabled only while
  in-flight; on click it stops further network calls.
- **Per-row report (always rendered, even on total failure):** a `<ul>`/`<table>`
  mapping 1:1 to input rows, each row showing exactly one outcome via the same
  `geo-status`-style word+glyph+color vocabulary, extended for import outcomes:
  - **created** → `✓` "Created" (`#137333`)
  - **geocode-failed** → `⚠` "Geocode failed" (`#b00020`)
  - **skipped-duplicate** → `–` "Skipped (duplicate)" (`#555`)
  - **missing-required-column** → `⚠` "Missing required column: {name}" (`#b00020`)
- **Copy / download errors:** real `<button>` "Copy errors" and/or "Download
  errors" (AC-014). Use the AA-safe `#1558b0` if rendered as a text-link;
  prefer a real `<button>`.
- The file `<input type="file" accept=".csv,text/csv">` is associated with a
  `<label>` via `useId()` (AC-019/AC-020).

---

## 8. CRUD List Surface (AC-015)

`CustomerList` extends the `.site-list` idiom inside `.site-panel`:

- Group by customer (`<h3>`/`<strong>` customer name) → nested `<ul>` of sites.
- Each site row shows name/address + a `geo-status` indicator + edit/move/delete
  affordances (real `<button>`s).
- **Edit-address / move / delete** update the lifted `sites` state in `App.tsx`
  (AC-010) so the map pin reactively re-renders — there is no full reload.
- **Delete-customer** opens a native `<dialog>` confirm stating "deletes N sites"
  before proceeding (AC-015). Confirm/cancel are real `<button>`s; ESC cancels.
- Reads use the `site_geo` view (RLS auto-scoped, no client tenant filter);
  writes target the `site`/`customer` base tables.

---

## 9. Reactive Map Layer (AC-010)

Visual contract for `sitePinsLayer` + `MapShell`:

- `sitePinsLayer(sites)` returns a deck.gl `ScatterplotLayer` keyed `'site-pins'`,
  `getPosition: [lng, lat]`, `getFillColor` = RGBA of `#1558b0`
  (`[21, 88, 176, 255]`), `getLineColor: [255,255,255,255]`,
  `radiusMinPixels: 6`, `lineWidthMinPixels: 1`, `pickable: true`.
- The `MapboxOverlay` instance is created ONCE on map init and held in a ref;
  on every `sites` change `MapShell` calls
  `overlay.setProps({ layers: [sitePinsLayer(sites)] })`. The empty
  `MapboxOverlay({ layers: [] })` placeholder is removed.
- Only un-failed (geocoded) sites get a pin; a failed-geocode site appears in the
  list flagged but has no map position to plot.
- Pin appears on add and moves on edit/move without a page reload (AC-010 /
  AC-015 reactive seam).

---

## 10. Anti-Patterns (Do NOT do)

- No Tailwind utilities, no `bg-*`/`text-*` classes, no CSS custom properties —
  this repo is plain semantic CSS classes + literal hex. Add named classes to
  `src/index.css`.
- No inline `style={{…}}` in the new TSX surfaces (the `MapShell` canvas inline
  style is the sole sanctioned exception).
- No arbitrary new hex values — reuse the verified palette (`#b00020`, `#555`,
  `#ddd`, `#1558b0`, `#137333`). Any further new color must be contrast-checked.
- Do NOT use `#1a73e8` for body-text links — it fails AA as text (~3.6:1). It is
  the focus-ring (non-text, 3:1) only. Use `#1558b0` for links (AC-020).
- Do NOT "fix" the existing `#1a73e8` focus outline — it is a correct non-text
  component color and is not a pre-existing failure (AC-020 / F-002).
- No status signalled by color alone — always word + glyph + color (AC-012).
- No `<div onClick>` — use real `<button>`/`<a>`/`<input>` (AC-020).
- No missing label association — every input gets a `<label htmlFor={useId()}>`.
- No silent drop of a failed-geocode site — persist + flag (AC-012).
- No removing the global `:focus-visible` outline or adding per-element focus
  overrides that weaken it.
- No solid-colored badge backgrounds — keep the flat colored-text indicator
  style consistent with W1.
- Do not stack three wide opaque panels over the small map — use a dialog for
  the forms (see §2).

---

## 11. Reference Patterns

Codebase north-star files (read these before implementing — they ARE the target
quality bar for this repo):

- `src/components/AuthGate.tsx` — form a11y: `useId()` label association, real
  `<label>`/`<button>`, `role="alert"`/`aria-live` errors, `.field`/`.form-error`,
  disabled-with-label-swap submit. **Copy this form pattern verbatim** for
  `CustomerForm`.
- `src/components/SiteList.tsx` — RLS-auto-scoped read (no client tenant filter),
  loading/error/ready state machine, SR-readable count text. **Extend this** for
  `CustomerList`.
- `src/index.css` — the entire CSS vocabulary: `.site-panel`, `.field`,
  `.form-error`, `:focus-visible`, the literal-hex palette. Add new rules here in
  the same style.
- `src/components/MapShell.tsx` — the deck.gl `MapboxOverlay` attach point
  (line 33) being changed to the reactive ref + `setProps` pattern (AC-010).

No external dashboard north-star is appropriate — this is a deliberately minimal
plain-CSS app, not a component-library dashboard. The W1 files are the standard.

---

## Deviation Log

| Area | What was missing in spec/ADR | Default applied |
|---|---|---|
| Panel arrangement for 3 new surfaces | Spec says `CustomerForm`/`CustomerImport`/`CustomerList` render in `App.tsx` but not their on-screen layout relative to W1's single left panel | Recommended: `CustomerList` in the persistent left `.site-panel`; `CustomerForm` + `CustomerImport` behind a native `<dialog>` opened from header/list buttons. Vertical-stack fallback (`gap:1rem`, max `22rem`) if no dialog. |
| Geocode status colors | AC-012 requires non-color-alone status but specifies no hex values | Chose `#137333` (geocoded, 5.9:1), `#b00020` (failed, reuse), `#555` (pending, reuse) — all AA-verified on white. |
| Map pin color/size | AC-010 requires a pin but no visual spec | `#1558b0` fill (`[21,88,176,255]`), white stroke, `radiusMinPixels:6`, `lineWidthMinPixels:1`. AA-safe and reuses the introduced link blue. |
| Import-outcome indicator styling | AC-013 requires a 1:1 per-row report but no visual vocabulary | Reused the `geo-status` word+glyph+color pattern, extended with created/skipped-duplicate/missing-column outcomes. |
| Helper/muted text size | No type scale defined beyond `.site-list h2` | `0.875rem` for helper/count/status text; `1rem` body baseline to match W1's rem rhythm. |
| Recovery-affordance layout (4 failure classes) | AC-012 names the four recovery paths but not their placement | Render the specific recovery control inline beside the "Failed" status word in the relevant site row. |
