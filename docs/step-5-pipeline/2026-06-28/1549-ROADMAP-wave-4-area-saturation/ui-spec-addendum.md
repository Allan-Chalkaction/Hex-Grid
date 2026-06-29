# UI Specification Addendum: Area-Saturation Heatmap (Wave 4)

**Feature:** area-saturation
**Date:** 2026-06-28
**Spec:** docs/step-3-specs/hex-grid/waves/area-saturation/area-saturation.md
**ADR:** docs/step-5-pipeline/2026-06-28/1549-ROADMAP-wave-4-area-saturation/adr.md (ADR-004)
**Token Mode:** project-tokens (plain semantic CSS classes + literal hex in `src/index.css` — NOT Tailwind, NOT CSS custom properties)

> **Token vocabulary (binding for this repo).** Same contract as the W2/W3
> addenda. This project uses **plain semantic CSS classes** in `src/index.css`
> with **literal hex** (`#1a73e8`, `#b00020`, `#555`, `#ddd`, `#1558b0`,
> `#137333`). There is no Tailwind, no utility classes, no CSS custom-property
> token layer. Do NOT introduce Tailwind utilities, `bg-*`/`text-*` classes, CSS
> variables, or arbitrary inline hex in TSX. Add new visual rules as **named
> semantic classes** in `src/index.css` and reference them by `className` — mirror
> the existing `.geo-status*` / `.zone-status*` / `.field` / `.field-checkbox` /
> `.confirm-dialog` conventions exactly. The deck.gl layers
> (`sitePinsLayer.ts` / `siteZonesLayer.ts` / the new `saturationLayer.ts`) are the
> one place RGBA arrays are authored in TS — they mirror the existing
> `[21, 88, 176]` / `[176, 0, 32]` literals and are NOT inline CSS.
>
> **One sanctioned new visual primitive this wave:** a **defined sequential
> color ramp** for the overlap-weighted saturation value (§4). The kickoff
> explicitly permits this ("no new arbitrary hex/spacing beyond a defined
> sequential color ramp"). It introduces exactly **two** new hex stops
> (`#c6dbef`, `#6baed6`) that, with the existing `#1558b0`, form an ordered
> light→dark Blues ramp anchored on the W3 zone blue. No other new hex.

---

## 0. Visual Context (what this wave adds)

W4 builds on the W3 surface unchanged: a full-bleed MapLibre map (`MapShell`,
absolute `inset:0`) with deck.gl translucent **zone circles** under **pins**, and
one floating left panel (`.site-panel`, `width:22rem`, `top:3rem left:1rem`)
holding `CustomerForm` (add) + `CustomerImport` + `CustomerList` (CRUD). The
aesthetic stays *minimal floating glass panels over a map* — no cards, no grid, no
component library.

W4 adds exactly **five** visible things, all built from the W3 vocabulary plus the
one sanctioned color ramp:

1. A **saturation heatmap** — a deck.gl `H3HexagonLayer` of overlap-weighted
   coverage cells, mounted as the BASE wash UNDER the W3 zones + pins.
2. A new **floating saturation control panel** (`.saturation-panel`, top-right —
   the free corner) holding the vertical selector, the layer toggles, the legend,
   and the textual saturation summary. This keeps the left CRUD panel untouched.
3. A **vertical `<select>`** (reuses `VERTICAL_OPTIONS`) — default *none selected*
   → no heatmap until a vertical is chosen.
4. A **saturation legend** (color-ramp → zone-count, with numeric labels — never
   color-alone) + a **prospecting highlight** of zero-coverage (open) cells.
5. **Layer toggles** (native checkboxes, `.field-checkbox`) — show/hide the
   heatmap; highlight open areas — plus the loading/empty states.

The visual job is to extend the established idiom — floating glass panels, the
`0.25 / 0.5 / 0.75 / 1rem` rhythm, native controls + `useId` labels,
`aria-live="polite"` status, word/number-not-color-alone signalling, deck.gl RGBA
layer config — **without inventing a new design language** (the one exception
being the sanctioned sequential ramp).

---

## 1. Component Selection

Everything is native HTML styled by semantic classes; the only new visual package
is the H3 layer (re-exported by `deck.gl`) + `h3-js` (compute, not visual). Reuse
the W2/W3 vocabulary:

| UI element | What to render | Reuse / new |
|---|---|---|
| Saturation heatmap | deck.gl `H3HexagonLayer` via `saturationLayer(cells)` | new `src/components/saturationLayer.ts` (mirror `siteZonesLayer.ts`) |
| Prospecting (open-cell) highlight | a second `H3HexagonLayer` style (green outline) via `prospectLayer(openCells)` | new builder in `saturationLayer.ts` (or sibling) |
| Saturation control panel | a floating glass panel (mirror `.site-panel` treatment) at top-right | new `.saturation-panel` class; new `SaturationPanel.tsx` |
| Vertical selector | native `<select>` inside a `.field` (label via `useId`), options from `VERTICAL_OPTIONS` | reuse `.field` + `.field select`; reuse `VERTICAL_OPTIONS` (do NOT re-author) |
| Heatmap on/off toggle | native `<input type="checkbox">` + inline `<label>` | reuse `.field-checkbox` |
| Prospecting on/off toggle | native `<input type="checkbox">` + inline `<label>` | reuse `.field-checkbox` |
| Saturation legend | a `<ul>` of swatch + numeric label rows | new `.sat-legend` / `.sat-legend__swatch` |
| Textual saturation summary (SR path) | `.helper-text` with `aria-live="polite"` | reuse `.helper-text` |
| "Jump to nearest open area" (optional, D5) | native `<button className="btn-secondary">` | reuse `.btn-secondary` |
| Computing / empty notices | `.helper-text` (`aria-live="polite"`) | reuse `.helper-text` |

Do NOT pull in any UI dependency. `h3-js` is a **compute** dependency (added to
`package.json` dependencies per the ADR); `H3HexagonLayer` imports from the
`deck.gl` umbrella exactly as `ScatterplotLayer` already does.

---

## 2. Layout & Spacing

Stay on the repo's `0.25rem / 0.5rem / 0.75rem / 1rem` scale. No arbitrary values.

| Element | Rule |
|---|---|
| `.saturation-panel` position | `position:absolute; top:3rem; right:1rem; z-index:1` (mirrors `.site-panel` but right-anchored — the free corner) |
| `.saturation-panel` box | `width:18rem; max-height:70vh; overflow:auto; padding:0.5rem 1rem; background:rgba(255,255,255,0.95); border:1px solid #ddd; border-radius:8px; display:flex; flex-direction:column; gap:0.5rem` (the W3 glass-panel treatment, narrower than the 22rem CRUD panel) |
| Panel heading (`<h2>`) | reuse `.panel-section h2` metrics (`font-size:1.1rem; margin:0.5rem 0`) |
| Vertical `<select>` field | reuse `.field` (`gap:0.25rem` label→control, `margin-bottom:1rem`) + `.field select` padding (`0.5rem`) |
| Toggle rows (`.field-checkbox`) | reuse as-is (`gap:0.5rem; margin-bottom:1rem; align-items:center`) |
| Legend (`.sat-legend`) | `list-style:none; margin:0.5rem 0; padding:0; display:flex; flex-direction:column; gap:0.25rem` |
| Legend row (`.sat-legend li`) | `display:flex; align-items:center; gap:0.5rem; font-size:0.875rem` |
| Legend swatch (`.sat-legend__swatch`) | `width:1rem; height:1rem; border:1px solid #555; border-radius:2px; flex:0 0 auto` (the `#555` hairline delineates every swatch regardless of fill lightness — see §4/§6) |
| Summary / computing helper line | reuse `.helper-text` (`margin:0.25rem 0`) |
| "Jump to nearest open area" button | reuse `.btn-secondary` (`padding:0.5rem 0.6rem; font-size:0.875rem`) |

The saturation panel and the left CRUD panel both float at `top:3rem`; the
`18rem` right panel + `22rem` left panel leave ample center map on a desktop
viewport (this is a desktop tool, per W2). No responsive collapse this wave
(documented in the Deviation Log).

---

## 3. Typography Hierarchy

No new type scale. Match W2/W3:

| Role | Element | Size | Weight | Color |
|---|---|---|---|---|
| Panel heading | `<h2>` | `1.1rem` | default bold | inherit (near-black) |
| Field label (vertical, toggles) | `<label>` | `1rem` | `400` | inherit |
| Select / checkbox text | `<select>`, toggle `<label>` | `1rem` | `400` | inherit |
| Legend row text ("3+ zones") | `.sat-legend li` | `0.875rem` | `400` | inherit (near-black) |
| Saturation summary / computing | `.helper-text` | `0.875rem` | `400` | `#555` |
| Empty-state notice | `.helper-text` | `0.875rem` | `400` | `#555` |

`1rem` stays the body baseline (desktop tool, per the W2 decision — the
"dashboard text-sm" guidance does not apply to this rem-based repo).

---

## 4. Color Token Usage — the saturation ramp (the one new primitive)

The overlap-weighted value is a **per-cell count of active same-vertical zones
covering the cell** (`0` = open). It maps to a **sequential, ordered, single-hue
(Blues) ramp** anchored on the existing W3 zone blue `#1558b0`. Light→dark =
low→high saturation; the deepest bucket IS the app's own zone blue, so "fully
locked up" literally reads as saturated zone-blue. **Open (0) is NOT a heatmap
fill** — it is left to show the basemap and is surfaced by the prospecting layer
(§7) and the legend.

### The ramp (sequential, light → dark)

| Coverage (overlap count) | Bucket label | deck.gl fill RGBA | Legend swatch hex | New hex? |
|---|---|---|---|---|
| `0` | **Open** | *(no heatmap fill)* — prospecting green outline (§7) | `#137333` outline swatch | no (existing green) |
| `1` | **1 zone** | `[198, 219, 239, 150]` | `#c6dbef` | **new** |
| `2` | **2 zones** | `[107, 174, 214, 170]` | `#6baed6` | **new** |
| `>= 3` | **3+ zones** | `[21, 88, 176, 190]` | `#1558b0` | no (W3 zone blue) |

Two new hex stops only (`#c6dbef`, `#6baed6`); the darkest bucket reuses the
existing `#1558b0`. Buckets are **discrete** (clamped at 3+), not a continuous
gradient — discrete steps are far more legible against a varied basemap and map
exactly to the legend's numeric labels (so the heatmap is never color-alone).

**`getFillColor` accessor** keys on `d.coverage`:

```
coverage <= 0  → handled by prospectLayer (no saturationLayer fill)
coverage === 1 → [198, 219, 239, 150]
coverage === 2 → [107, 174, 214, 170]
coverage >= 3  → [21, 88, 176, 190]
```

### Why these alphas

A fixed-RGB, **lightness-stepped** ramp at moderate alpha (150–190) reads more
reliably over the OpenFreeMap `liberty` light basemap than an alpha-only ramp, and
still lets street/label context show through for a "wash" feel. The W3 zone
circles sit ON TOP at their much lower alpha (`38`–`46` fill), so the heatmap
remains visible *through* the zones and the two never become indistinguishable
(the zones add a crisp stroked ring the wash lacks).

### Contrast bars

| Pairing | Bar | Result |
|---|---|---|
| Legend row text (near-black) on white panel | 4.5:1 text | PASS (~16:1) |
| Saturation summary `#555` on white | 4.5:1 text | PASS (~7.5:1, W2-verified) |
| Legend swatch `#555` hairline border on white | 3:1 non-text | PASS (~7.5:1) — delineates every swatch regardless of fill lightness |
| Heatmap buckets vs each other / basemap | 3:1 graphical (ordered) | PASS by ordered lightness + the swatch border + numeric labels; the lightest bucket is reinforced by the legend, never color-alone |
| Prospecting green outline `#137333` on basemap | 3:1 graphical | PASS (W3-verified ~5.9:1 on white) |
| Focus outline `#1a73e8` (all new controls) | 3:1 non-text | PASS (inherits global `:focus-visible`) |

Surface layering (extends W3): map canvas → **saturation H3 wash** → **prospect
open-cell outlines** → translucent W3 zone circles → pins → floating white panels
→ near-black text → `#555` muted.

---

## 5. Saturation Heatmap Layer (item 1 — detail)

**New builder:** `saturationLayer(cells: { h3: string; coverage: number }[])`
returns a deck.gl `H3HexagonLayer` keyed `'saturation'`, mirroring the
`siteZonesLayer.ts` factory shape (data filter → layer config → `updateTriggers`):

- `data`: only **covered** cells (`coverage >= 1`); open cells are excluded here
  and rendered by the prospecting builder (§7).
- `getHexagon: (d) => d.h3`.
- `extruded: false` — **flat** (no elevation; a saturation wash, not a 3-D bar
  field; per ADR D4).
- `filled: true`, `stroked: false`, `pickable: false` (the pins own picking; the
  wash is passive).
- `getFillColor`: the discrete ramp accessor in §4 (keyed on `d.coverage`).
- `updateTriggers: { getFillColor: [selectedVertical, dataVersion, resolution] }`
  — deck.gl re-evaluates only on a real change (ADR D1/perf gate), never per
  frame.

**Z-order (load-bearing, per ADR D4).** Mount FIRST in the `MapShell` overlay
array so the wash sits UNDER the zones and pins:

```
overlay.setProps({ layers: [
  saturationLayer(cells),
  prospectLayer(openCells),      // §7 — open cells, above the wash, below zones
  siteZonesLayer(sites, conflictIds),
  sitePinsLayer(sites),
] })
```

deck.gl renders bottom→top, so: saturation wash → open-cell outlines → W3 zone
circles → pins. The wash never occludes a zone ring or a pin.

**Update cadence (extends the W3 reactive seam).** The cell set is recomputed on
viewport-idle (`moveend`, debounced ~200 ms) AND on `selectedVertical` change AND
on data reload (`dataVersion`) — exactly the W3 "recompute on data change, never
per frame" posture, plus the viewport trigger this wave introduces. The
`MapShell` reactive effect (`MapShell.tsx:64-68`) gains the cell set in its
dependency list; the compute itself lives in App/MapShell state per the ADR
(`selectedVertical` lifted like `conflictIds`). When `selectedVertical` is `null`
**or** the heatmap toggle is off, the `saturationLayer` is **omitted from the
array entirely** (not rendered empty) — first paint stays byte-identical to W3.

---

## 6. Vertical Selector + Layer Toggles (items 2 & 5 — detail)

All three controls live in the new top-right `.saturation-panel`, stacked.

### Vertical selector

**Control:** a native `<select>` over `VERTICAL_OPTIONS` (`customers.ts:70-80`) —
reuse the 8-token vocabulary, do NOT re-author it. Same control type and rationale
as the W3 vertical picker.

**Empty/default state (decided):** the first option is **"Select vertical…"**
(`value=""`) and is the default. While it is selected, `selectedVertical = null`,
**no heatmap layer is mounted**, and the panel shows the empty-state notice
(§8). This avoids an arbitrary default vertical and keeps first paint identical
to W3.

| Option label | `<option value>` |
|---|---|
| Select vertical… | `""` → `selectedVertical = null` (no heatmap) |
| Gas / convenience | `"gas"` |
| Grocery | `"grocery"` |
| … (all of `VERTICAL_OPTIONS`) | … |

**Label + a11y:** `const verticalId = useId();` →
`<label htmlFor={verticalId}>Saturation vertical</label>` +
`<select id={verticalId}>`. Real visible label text; inherits the global
`:focus-visible` outline.

### Heatmap on/off toggle

A native checkbox (`.field-checkbox`): `Show saturation heatmap`. **Default
checked.** It is **disabled while `selectedVertical === null`** (nothing to
show); once a vertical is chosen it lets the user hide the wash to inspect the W3
zones/pins beneath WITHOUT losing the selected vertical. When unchecked, the
`saturationLayer` is omitted (zones + pins remain).

`const heatmapId = useId();` → `<input type="checkbox" id={heatmapId} disabled={!selectedVertical} …>` +
`<label htmlFor={heatmapId}>Show saturation heatmap</label>`.

### Prospecting on/off toggle

A second native checkbox (`.field-checkbox`): `Highlight open areas`. **Default
unchecked** (prospecting is an opt-in lens). Also disabled while
`selectedVertical === null`. Independent of the heatmap toggle — a user may
highlight open areas with or without the full wash. Detail in §7.

**Composition with the existing CustomerList panel:** the saturation panel is a
SEPARATE floating panel (top-right); it does not touch `App`'s left `<main>`
`.site-panel` or the `CustomerList` CRUD surface. `selectedVertical` /
`showHeatmap` / `showProspecting` are new App-level state (lifted alongside
`conflictIds`, `App.tsx:53-56`) and passed to both the new `SaturationPanel` and
`MapShell`.

---

## 7. Prospecting View — "open area near here" (item 4 — detail)

**What it surfaces:** the **zero-coverage** cells already computed for the current
viewport (`coverage === 0`), ranked by distance to the viewport center, top-N
(per ADR D5). Because the cells are already viewport-bounded, "near here" is
intrinsic.

**Distinct highlight style (deck.gl `prospectLayer(openCells)`):** a second
`H3HexagonLayer`, visually distinct from the blue saturation wash:

- `data`: top-N nearest `coverage === 0` cells.
- `extruded: false`, `pickable: false`.
- `filled: true`, `getFillColor: [19, 115, 51, 35]` (a faint green wash,
  `#137333`).
- `stroked: true`, `getLineColor: [19, 115, 51, 230]` (`#137333`),
  `getLineWidth: 2`, `lineWidthUnits: 'pixels'`.

Green outline = "open / available / opportunity" — semantically the inverse of
the deepening blue "locked-up" wash, and it deliberately **avoids red** (red stays
reserved for W3 *conflict*, so the two map meanings never collide). Open cells, by
definition, have no covering zone, so a W3 zone circle never sits on top of a
prospect highlight.

**Mount order:** above the saturation wash, below zones + pins (§5 array). When
the prospecting toggle is off OR `selectedVertical === null`, the `prospectLayer`
is omitted entirely.

**Optional "Jump to nearest open area" button** (per ADR D5): a
`<button className="btn-secondary">Jump to nearest open area</button>` in the
panel. On click, pan/ease the map to the nearest `coverage === 0` cell's centroid
and announce via the summary `aria-live="polite"` ("Centered on nearest open
area."). Disabled when there are no open cells in view or no vertical selected.

**Keyboard / SR path:** the button is a real `<button>` (Tab-focusable, Enter/
Space activates, inherits `:focus-visible`). The canvas highlight itself is not
SR-accessible (see §8) — the accessible carrier is the **textual summary** ("N
open cells near center", §8) plus this button.

---

## 8. States, Keyboard & Screen-Reader Behavior (item 6)

**The canvas heatmap is not SR-accessible by nature.** The accessible path is the
panel chrome: the **legend** (color → numeric label) + a **textual saturation
summary** in `.helper-text aria-live="polite"`. This mirrors W3's "map is
`role="application"`; a11y is scoped to the chrome" decision (A11Y-011).

### Legend (item 3 — detail)

Rendered in the panel only when `selectedVertical !== null` AND the heatmap is
shown. A `<ul className="sat-legend">`; each `<li>` = a swatch span
(`aria-hidden="true"`, background = the bucket fill) + **real text** carrying the
count:

| Swatch | Text (real, SR-announced) |
|---|---|
| `#137333` outline swatch | `Open (0 zones)` |
| `#c6dbef` | `1 zone` |
| `#6baed6` | `2 zones` |
| `#1558b0` | `3+ zones` |

The numeric label is the authoritative carrier — **never color-alone**. Each
swatch has the `#555` hairline border (§2) so it is delineated even when its fill
is very light. (When prospecting is off, keep the "Open (0 zones)" row — it still
documents what an uncolored cell means.)

### Textual saturation summary (SR carrier)

One `.helper-text` line, `aria-live="polite"`, updated on every recompute:

> Saturation for **{vertical label}**: {coveredCount} covered cells,
> **{openCount} open** cells near center.

This is the accessible equivalent of the heatmap + prospecting highlight — a
screen-reader user gets the same answer ("how locked up / how much open area")
without the canvas.

### Loading / computing

- While the debounced `moveend` recompute (or a vertical-change recompute) runs:
  `.helper-text aria-live="polite"` → **"Computing saturation…"**. Do not flash a
  stale legend/summary — hold the prior result or show the computing notice.
- The cell-count cap (ADR perf gate): if the viewport exceeds the cap at the
  current resolution, raise resolution / skip and note **"Zoom in to compute
  saturation"** in the same helper line (never silently render nothing).

### Empty

- `selectedVertical === null` → no heatmap/legend; panel shows
  **"Select a vertical to view saturation."** (`.helper-text`).
- Vertical selected but **no zones of that vertical in view** → no fill;
  summary reads **"No {vertical} zones in this area — all open."** (every visible
  cell is open; prospecting, if on, highlights them).
- No customers / no located sites → same as W3 (the heatmap simply has nothing to
  cover; the empty notice applies).

### Keyboard

- Vertical `<select>`, both toggle `<input type="checkbox">`, and the "Jump to
  nearest open area" `<button>` are all native: Tab to focus, native activation
  (arrows/type-ahead on the select; Space toggles the checkboxes; Enter/Space the
  button). All inherit the global `:focus-visible` (`2px #1a73e8`, 2px offset) —
  do NOT override.
- No `<div onClick>`; every interactive element is a real `<select>` /
  `<input>` / `<button>` (W2 AC-020).
- Disabled controls (toggles while no vertical selected) use the native
  `disabled` attribute (removed from the tab order, SR-announced as dimmed) — not
  an `aria-disabled` div.

### Screen reader

- Every new control has a `<label htmlFor={useId()}>` — no orphan controls.
- Legend swatches are `aria-hidden`; the count text is the announced carrier.
- The textual summary + "Computing saturation…" use `aria-live="polite"`; nothing
  uses `role="alert"` (no errors in this read-only view).
- The map canvas stays `role="application"` (W3); saturation a11y is fully carried
  by the panel legend + summary.

### Color contrast

All panel text (near-black, `#555`) clears AA (≥4.5:1) on white. The ramp buckets
are ordered by lightness, bordered by a `#555` hairline in the legend, and always
paired with numeric labels — the 3:1 graphical bar + the never-color-alone rule
are both satisfied. The `#137333` prospect outline clears 3:1 graphical
(W3-verified). The `#1a73e8` focus ring is the non-text 3:1 component color (do
not "fix" it — W2 F-002).

---

## 9. Anti-Patterns (Do NOT do)

- No Tailwind utilities / `bg-*`/`text-*` / CSS variables — plain semantic CSS
  classes + literal hex only. Add `.saturation-panel`, `.sat-legend`,
  `.sat-legend__swatch` to `src/index.css`.
- No new arbitrary hex **beyond the two sanctioned ramp stops** (`#c6dbef`,
  `#6baed6`); everything else reuses `#1558b0`, `#137333`, `#555`, `#ddd`. The
  deck.gl RGBA arrays use the same literals.
- No **continuous** gradient — use the discrete 1 / 2 / 3+ buckets that map
  exactly to the legend's numeric labels.
- No saturation signalled by **color alone** — the legend numeric labels + the
  textual summary are the authoritative SR carriers; the canvas wash is the
  visual reinforcement.
- No **red** for the heatmap or prospecting — red is reserved for W3 conflict;
  saturation is the Blues ramp, prospecting is `#137333` green.
- No **elevation / extruded** hexes — the heatmap is flat (`extruded:false`).
- No mounting the saturation wash above the zones/pins — order is
  `[saturationLayer, prospectLayer, siteZonesLayer, sitePinsLayer]` (wash under
  open-outlines under zones under pins).
- No rendering an **empty** `saturationLayer` when no vertical is selected or the
  toggle is off — omit it from the array (first paint identical to W3).
- No per-frame / per-render recompute — recompute on debounced `moveend`,
  `selectedVertical` change, and data reload only; `updateTriggers` keyed on
  `[selectedVertical, dataVersion, resolution]` (ADR D1/perf gate).
- No `<div onClick>` and no custom select/toggle where a native `<select>` /
  `<input type="checkbox">` / `<button>` serves.
- No removing/weakening the global `:focus-visible` outline; no per-element focus
  override.
- No `aria-disabled` divs for the gated toggles — use the native `disabled`
  attribute.
- No inline `style={{…}}` in TSX (the `MapShell` canvas + the legend swatch
  background are the only sanctioned spots; the swatch background may be set via a
  data-driven inline `style` since the bucket color is dynamic — mirror how the
  deck.gl layers carry RGBA, kept to the swatch span only).
- No re-authoring `VERTICAL_OPTIONS` — import and reuse it.

---

## 10. Reference Patterns

Codebase north-star files — read before implementing; they ARE the quality bar:

- `src/components/siteZonesLayer.ts` — the deck.gl layer factory to mirror for
  `saturationLayer.ts` (RGBA-literal coloring keyed on a per-datum value, the
  data filter, `updateTriggers` with a stable key). **Copy this shape** for the
  `H3HexagonLayer` builder.
- `src/components/MapShell.tsx` — the reactive `overlay.setProps({layers:[…]})`
  seam (`:64-68`) to extend with the new layer array order; the
  `role="application"` canvas a11y posture.
- `src/App.tsx` — the lifted-state + "recompute on data change, never per frame"
  pattern (`conflictIds`/`conflictsBySite`, `:44-99`); add `selectedVertical` /
  `showHeatmap` / `showProspecting` + the viewport-driven cell compute here (or in
  `MapShell`, per the ADR).
- `src/components/CustomerForm.tsx` / `CustomerList.tsx` — the `useId` label
  association, native `<select>` + `.field-checkbox` toggle idiom, `.helper-text`
  + `aria-live="polite"` status, disabled-with-state controls.
- `src/lib/customers.ts` — `VERTICAL_OPTIONS` + `verticalLabel()` (import; do not
  re-author).
- `src/index.css` — `.site-panel` (the glass-panel treatment to clone for
  `.saturation-panel`), `.field` / `.field-checkbox` / `.helper-text` /
  `.btn-secondary`, `.geo-status*` / `.zone-status*` (the word/number-not-
  color-alone idiom). Add `.saturation-panel` / `.sat-legend*` here in the same
  style.

No external dashboard north-star — this is a deliberately minimal plain-CSS app;
the W1/W2/W3 files are the standard.

---

## Deviation Log

| Area | What was missing / divergent in spec/ADR | Default applied |
|---|---|---|
| Coverage metric | ADR-004 D2 chose **boolean** in-any-zone first (overlap-weighted as a deferred drop-in); the kickoff *decided context* + the cto SIMPLIFY disposition pick **overlap-weighted** (per-cell zone count; 0 = open). | Designed the UI to **overlap-weighted** per the binding decided-context (ADR D2's own "drop-in extension" note + Alternatives confirm the loop is identical) — the discrete 1/2/3+ ramp keys on the count, not a boolean. The shared `effectiveRadiusMi` helper + per-cell loop are unchanged; only the accessor returns a count. |
| Control placement | Prompt offered map-overlay control vs side panel; not decided. | A **new floating top-right `.saturation-panel`** (the free corner; mirrors `.site-panel` glass) holding selector + toggles + legend + summary — leaves the left CRUD panel untouched and groups all saturation chrome. |
| Color ramp stops | Prompt asked to *define* the ramp; ADR left it open ("a single hue ramping alpha … the `[176,0,32]`/`[21,88,176]` family"). | A discrete sequential **Blues** ramp anchored on the existing `#1558b0`: `#c6dbef` (1) → `#6baed6` (2) → `#1558b0` (3+); two new hex only. Deliberately NOT red (red = W3 conflict). Discrete buckets, not a continuous gradient (legibility + 1:1 with the legend labels). |
| Open (0) rendering | Whether 0/open is a heatmap color or absent. | Open = **no heatmap fill** (basemap shows through); surfaced by the prospecting green-outline layer + the "Open (0 zones)" legend row + the textual summary. |
| Prospecting trigger | Toggle vs always-on; threshold. | A **toggle** (`Highlight open areas`, default off), gated on a selected vertical, independent of the heatmap toggle; threshold is strictly `coverage === 0` (the only meaningful "open" under overlap-weighted), top-N nearest to viewport center per ADR D5. Optional "Jump to nearest open area" button included. |
| Heatmap on/off vs vertical gate | Two overlapping gates (no vertical vs toggle). | Vertical selector is the primary gate (none → no layer); the heatmap toggle (default on, disabled until a vertical is chosen) lets the user hide the wash without losing the selected vertical. |
| Elevation | ADR says keep flat; confirm. | `extruded:false` — flat wash; explicitly no 3-D bars. |
| SR accessibility of the canvas | Canvas heatmap is inherently not SR-accessible. | Accessible path = the legend (numeric labels) + a `aria-live="polite"` **textual summary** ("N covered cells, M open cells near center") — mirrors W3's chrome-scoped a11y. |
| Responsive layout | Two floating panels (22rem left + 18rem right) on small viewports. | No responsive collapse this wave (desktop tool, per W2); panels float and the map fills the remaining center. Flagged for a future pass if mobile becomes in scope. |
