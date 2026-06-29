# UI Specification Addendum: Reference Overlays (Wave 5)

**Feature:** reference-overlays
**Date:** 2026-06-28
**Spec:** docs/step-3-specs/hex-grid/waves/reference-overlays/reference-overlays.md
**ADR:** docs/step-5-pipeline/2026-06-28/2034-ROADMAP-wave-5-reference-overlays/adr.md (ADR-005)
**Token Mode:** project-tokens (plain semantic CSS classes + literal hex in `src/index.css` — NOT Tailwind, NOT CSS custom properties)

> **Token vocabulary (binding for this repo).** Same contract as the W2/W3/W4
> addenda. This project uses **plain semantic CSS classes** in `src/index.css`
> with **literal hex** (`#1a73e8`, `#b00020`, `#555`, `#ddd`, `#1558b0`,
> `#137333`, plus the W4 ramp stops `#c6dbef` / `#6baed6`). There is no Tailwind,
> no utility classes, no CSS custom-property token layer. Do NOT introduce
> Tailwind utilities, `bg-*`/`text-*` classes, CSS variables, or arbitrary inline
> hex in TSX. Add new visual rules as **named semantic classes** in
> `src/index.css` and reference them by `className` — mirror the existing
> `.saturation-panel` / `.sat-legend` / `.field` / `.field-checkbox` /
> `.helper-text` conventions exactly. The deck.gl layers (`sitePinsLayer.ts`,
> `siteZonesLayer.ts`, `saturationLayer.ts`, the new `referenceLabelsLayer.ts`)
> are the one place RGBA arrays are authored in TS — they mirror the existing
> `[21, 88, 176]` / `[176, 0, 32]` literals and are NOT inline CSS. The MapLibre
> ZCTA `paint`/`layout` objects (`zctaSource.ts`) are the one place MapLibre style
> spec colors are authored — also literal hex, not inline CSS.
>
> **New visual primitives sanctioned this wave (and ONLY these):**
> 1. A **per-vertical categorical color palette** (`VERTICAL_COLORS` in
>    `src/lib/verticalStyle.ts`) — 8 stable categorical colors + a neutral
>    fallback (§4). This is the one new color family; it is deliberately chosen to
>    avoid the W3 conflict-red, W4 saturation-blue, and W4 prospect-green
>    semantics.
> 2. **Reference-label styling** for the capitals/metros `TextLayer`s (dark text +
>    white halo) — reuses near-black / `#555` text hues, no new hex (§5).
> 3. **ZCTA fill/line styling** — a near-transparent fill + a subtle neutral grey
>    line (§6). The line introduces exactly one neutral grey (`#6b7280`) shared
>    with the palette fallback; no other new hex.

---

## 0. Visual Context (what this wave adds)

W5 builds on the W4 surface unchanged: a full-bleed MapLibre map (`MapShell`,
absolute `inset:0`, OpenFreeMap `liberty` keyless basemap) with a deck.gl overlay
of saturation wash → prospect outlines → zone circles → pins, a floating **left**
CRUD panel (`.site-panel`, `22rem`), and a floating **top-right** control panel
(`.saturation-panel`, `18rem`). The aesthetic stays *minimal floating glass panels
over a map* — no cards, no grid, no component library.

W5 adds exactly **five** visible things, all built from the W2/W3/W4 vocabulary
plus the three sanctioned new primitives:

1. **Color-by-vertical pins** — every site pin recolored by its `vertical` via a
   stable categorical palette (always-on; no control), with a **vertical color
   legend** in the panel.
2. **An opt-in "show only this vertical's sites" pin filter** — a single checkbox
   that filters pins to the shared `selectedVertical`; composes with (does not
   replace) the always-on coloring.
3. **Capitals + metros label layers** — deck.gl `TextLayer`s from static JSON,
   rendered as halo'd reference labels ABOVE the pins.
4. **A toggleable ZIP / ZCTA boundary overlay** — a MapLibre native vector source
   (subtle fill + line) BELOW the pins; click a box → a popup with the ZCTA code;
   gracefully **disabled** with a helper note when `VITE_ZCTA_TILES_URL` is unset.
5. **The consolidated "Map layers" panel** — the W4 `SaturationPanel` refactored
   in place: heading → "Map layers", the shared vertical selector + the filter
   checkbox, two sectioned toggle fieldsets (**Reference** / **Analysis**), the
   new vertical color legend, and the existing W4 saturation legend + aria-live
   summary + jump button, all kept.

The visual job is to extend the established idiom — floating glass panels, the
`0.25 / 0.5 / 0.75 / 1rem` rhythm, native controls + `useId` labels,
`aria-live="polite"` status, never-color-alone signalling, deck.gl RGBA layer
config — **without inventing a new design language** (the three sanctioned
primitives above are the only new visual vocabulary). The **left CRUD panel is
untouched**; this wave touches only the map layers + the top-right panel.

---

## 1. Component Selection

Everything is native HTML styled by semantic classes; the new visual mechanisms
are deck.gl layers + a MapLibre native source (no UI dependency). Reuse the
W2/W3/W4 vocabulary:

| UI element | What to render | Reuse / new |
|---|---|---|
| Per-vertical pin coloring | `sitePinsLayer(sites, { selectedVertical, filterToVertical })` — `getFillColor` keyed on `d.vertical` | **edit** `src/components/sitePinsLayer.ts`; new `src/lib/verticalStyle.ts` (`VERTICAL_COLORS`) |
| Capitals label layer | deck.gl `TextLayer` via `capitalsLayer(data)` | new `src/components/referenceLabelsLayer.ts` + `src/data/capitals.json` |
| Metros label layer | deck.gl `TextLayer` via `metrosLayer(data)` | new builder in `referenceLabelsLayer.ts` + `src/data/metros.json` |
| ZCTA boundary overlay | MapLibre native vector source + `zcta-fill` / `zcta-line` style layers | new `src/components/zctaSource.ts` (`addZctaSource` / `setZctaVisible` / `zctaConfigured`) |
| ZCTA click popup | `maplibregl.Popup` at the click point showing the ZCTA5 code | reuse MapLibre's native Popup (new `.zcta-popup` class for minimal styling) |
| Consolidated "Map layers" panel | the existing floating top-right glass panel, refactored in place | **edit** `SaturationPanel.tsx` (heading + fieldsets + filter checkbox + vertical legend); reuse `.saturation-panel` shell |
| Shared vertical selector | native `<select>` over `VERTICAL_OPTIONS` (label via `useId`) — **relabel** "Saturation vertical" → "Vertical" | reuse `.field` + `.field select`; reuse `VERTICAL_OPTIONS` (do NOT re-author) |
| Pin filter checkbox | native `<input type="checkbox">` "Show only this vertical's sites" | reuse `.field-checkbox` |
| Reference / Analysis toggle groups | native `<fieldset>` + `<legend>` wrapping `.field-checkbox` rows | new `.layers-fieldset` / `.layers-fieldset legend` |
| Vertical color legend | a `<ul>` of swatch + label rows over `VERTICAL_OPTIONS` + a fallback row, inside a `<details>` to manage height | new `.vertical-legend`; reuse `.sat-legend__swatch` swatch metrics |
| Saturation legend (kept) | the existing `.sat-legend` (conditional) | reuse as-is (W4) |
| aria-live summary (kept) | `.helper-text` with `aria-live="polite"` | reuse as-is (W4) |
| Disabled-ZIP helper note | `.helper-text` tied via `aria-describedby` | reuse `.helper-text` |

Do NOT pull in any UI dependency. Capitals/metros are bundled static JSON
(no fetch, no key). ZCTA tiles are consumed by the MapLibre basemap library
already in the tree. `TextLayer` imports from the `deck.gl` umbrella exactly as
`ScatterplotLayer` / `H3HexagonLayer` already do.

---

## 2. Layout & Spacing

Stay on the repo's `0.25rem / 0.5rem / 0.75rem / 1rem` scale. No arbitrary values.
The panel shell is the existing W4 `.saturation-panel` (`top:3rem; right:1rem;
width:18rem; max-height:70vh; overflow:auto; gap:0.5rem`) — **unchanged metrics**;
only its content grows.

| Element | Rule |
|---|---|
| Panel shell | reuse `.saturation-panel` as-is (`width:18rem; max-height:70vh; overflow:auto; display:flex; flex-direction:column; gap:0.5rem; padding:0.5rem 1rem`) — the height cap + scroll already handle the taller content (§5/§11 height note) |
| Panel heading (`<h2>`) | reuse `.saturation-panel h2` (`font-size:1.1rem; margin:0.5rem 0`); text → **"Map layers"** |
| Vertical `<select>` field | reuse `.field` (`gap:0.25rem`, `margin-bottom:1rem`) + `.field select` padding (`0.5rem`) |
| Filter checkbox row | reuse `.field-checkbox` (`gap:0.5rem; align-items:center; margin-bottom:1rem`) |
| Toggle fieldset (`.layers-fieldset`) | `border:1px solid #ddd; border-radius:6px; padding:0.5rem 0.75rem; margin:0 0 0.5rem; display:flex; flex-direction:column; gap:0.25rem` |
| Fieldset legend | `font-size:0.875rem; font-weight:600; padding:0 0.25rem` |
| Checkbox rows inside a fieldset | reuse `.field-checkbox` but **override** `margin-bottom:0` inside `.layers-fieldset` (the fieldset `gap:0.25rem` owns the rhythm) |
| Vertical color legend (`.vertical-legend`) | `list-style:none; margin:0.25rem 0; padding:0; display:flex; flex-direction:column; gap:0.25rem` (mirrors `.sat-legend`) |
| Vertical legend row | `display:flex; align-items:center; gap:0.5rem; font-size:0.875rem` |
| Legend swatch | reuse `.sat-legend__swatch` (`width:1rem; height:1rem; border:1px solid #555; border-radius:2px; flex:0 0 auto`) — the `#555` hairline delineates every swatch regardless of fill |
| `<details>` wrapper for the vertical legend | `<summary>` reuses `.helper-text`-weight type (`font-size:0.875rem`); no new box — keeps the panel compact when collapsed |
| Saturation legend (kept) | reuse `.sat-legend` (W4) |
| Summary / helper lines (kept) | reuse `.helper-text` (`margin:0.25rem 0`) |
| Jump button (kept) | reuse `.btn-secondary` |

No new floating surface; no change to the left `.site-panel` or the map canvas
`inset:0`. No responsive collapse this wave (desktop tool — see Deviation Log).

---

## 3. Typography Hierarchy

No new type scale. Match W2/W3/W4:

| Role | Element | Size | Weight | Color |
|---|---|---|---|---|
| Panel heading "Map layers" | `<h2>` | `1.1rem` | default bold | inherit (near-black) |
| Fieldset legend ("Reference layers" / "Analysis layers") | `<legend>` | `0.875rem` | `600` | inherit |
| Field label ("Vertical"), checkbox labels | `<label>` | `1rem` | `400` | inherit |
| Select / checkbox text | `<select>`, toggle `<label>` | `1rem` | `400` | inherit |
| Vertical legend row text | `.vertical-legend li` | `0.875rem` | `400` | inherit (near-black) |
| `<details>` summary ("Vertical colors") | `<summary>` | `0.875rem` | `400` | inherit |
| Saturation summary / computing (kept) | `.helper-text` | `0.875rem` | `400` | `#555` |
| Disabled-ZIP helper note | `.helper-text` | `0.875rem` | `400` | `#555` |
| Map reference labels — capitals | `TextLayer` (canvas) | `13px` | bold (sdf) | near-black `[40,40,40]` + white halo (§5) |
| Map reference labels — metros | `TextLayer` (canvas) | `11px` | normal (sdf) | dark grey `[85,85,85]` + white halo (§5) |
| ZCTA popup zip code | `.zcta-popup` text | `0.875rem` | `600` | inherit (near-black) |

`1rem` stays the chrome body baseline (desktop tool, per the W2 decision). Map
label sizes are **pixel-sized** (deck.gl canvas convention, like the existing
layer radii) — they are not part of the rem chrome scale.

---

## 4. Color Token Usage — the per-vertical palette (the primary new primitive)

`VERTICAL_COLORS` (in `src/lib/verticalStyle.ts`, next to the `VERTICAL_OPTIONS`
vocabulary it keys on) is a `Record<token, [r,g,b]>` over the 8 `VERTICAL_OPTIONS`
tokens, plus a **neutral fallback** for a `null`/unknown vertical. It is a
**categorical** palette (distinct hues), deliberately chosen to avoid the three
reserved semantic colors so a pin's vertical never reads as a conflict, a
saturation bucket, or a prospect cell:

- **Reserved — never used for a vertical:** conflict-red `#b00020`
  (`[176,0,32]`); saturation Blues `#c6dbef` / `#6baed6` / `#1558b0`
  (the `#1558b0` blue family is also the old pin color and the zone stroke);
  prospect-green `#137333` (`[19,115,51]`).

### The palette (categorical, accessible on the light basemap)

Pins are 6px dots with the existing **1px white stroke** (`sitePinsLayer.ts:26`) —
the stroke is itself a graphical-separation cue against the basemap and the
translucent wash/zones beneath. Every fill below additionally clears the **3:1
graphical-object** bar against pure white (the conservative worst case for the
`liberty` light basemap); most clear 4.5:1.

| Vertical token | Label (from `VERTICAL_OPTIONS`) | deck.gl fill RGB | Hex | Hue family | Contrast vs white |
|---|---|---|---|---|---|
| `gas` | Gas / convenience | `[194, 87, 10]` | `#c2570a` | orange | ~4.5:1 |
| `grocery` | Grocery | `[162, 28, 175]` | `#a21caf` | magenta | ~6.3:1 |
| `pharmacy` | Pharmacy | `[15, 118, 110]` | `#0f766e` | teal | ~5.5:1 |
| `qsr` | Quick-service restaurant (QSR) | `[190, 24, 93]` | `#be185d` | rose | ~6.0:1 |
| `fitness` | Fitness | `[77, 124, 15]` | `#4d7c0f` | olive-lime | ~5.0:1 |
| `automotive` | Automotive | `[146, 64, 14]` | `#92400e` | brown | ~7.1:1 |
| `banking` | Banking | `[71, 85, 105]` | `#475569` | slate | ~7.6:1 |
| `hotel` | Hotel / lodging | `[126, 34, 206]` | `#7e22ce` | violet | ~7.0:1 |
| *(null / unknown)* | No vertical | `[107, 114, 128]` | `#6b7280` | neutral grey | ~4.8:1 |

**Distinctness note (honest):** eight categorical colors cannot all be reliably
told apart at 6px by color alone — the closest pair is `gas` (orange) vs
`automotive` (brown), separated here by lightness (4.5:1 vs 7.1:1). That is by
design: **color-by-vertical is orientation, not the authoritative identity
channel.** The disambiguators are (a) the **vertical color legend** in the panel
(swatch + real text — never color-alone), and (b) the **opt-in single-vertical
filter** (§ pin filter), which isolates one vertical when precise reading matters.
This mirrors the W3/W4 "map color is reinforcement; the chrome carries the
accessible signal" stance.

### `getFillColor` accessor (in `sitePinsLayer.ts`)

```
getFillColor: (d) => VERTICAL_COLORS[d.vertical ?? ''] ?? VERTICAL_NEUTRAL
```

where `VERTICAL_NEUTRAL = [107, 114, 128]`. The fill is **opaque** (no alpha — a
pin must stay crisp over the translucent wash/zones), matching the current
`getFillColor: [21, 88, 176]`. `updateTriggers.getFillColor` is **not required**
for a recolor (the palette is static and the color depends only on the per-datum
`d.vertical`); the redraw happens because the layer is rebuilt when `sites` /
`selectedVertical` / `filterToVertical` change. If a stable key is wanted to
mirror the `siteZonesLayer` `conflictKey` idiom, key it on a constant
(`'vertical-palette-v1'`) — never per frame.

### Contrast bars (chrome)

| Pairing | Bar | Result |
|---|---|---|
| Panel text (near-black) on white panel | 4.5:1 text | PASS (~16:1) |
| Fieldset legend / vertical legend text (near-black) on white | 4.5:1 text | PASS (~16:1) |
| Helper / summary `#555` on white (kept) | 4.5:1 text | PASS (~7.5:1, W2-verified) |
| Legend swatch `#555` hairline border on white | 3:1 non-text | PASS (~7.5:1) — delineates every swatch fill |
| Each `VERTICAL_COLORS` fill vs white (graphical) | 3:1 graphical | PASS (table above; min ~4.5:1) |
| `VERTICAL_COLORS` swatches vs each other in the legend | 3:1 graphical | PASS by hue + the `#555` border + the real text label (never color-alone) |
| Focus outline `#1a73e8` (all new controls) | 3:1 non-text | PASS (inherits global `:focus-visible`) |

Surface layering (extends W4, additions in **bold**): map canvas → **ZCTA fill →
ZCTA line** (MapLibre native, below the overlay) → saturation wash → prospect
outlines → zone circles → **vertical-colored pins** → **metro labels → capital
labels** (deck overlay, labels last) → floating white panels → near-black text →
`#555` muted.

---

## 5. Capitals + Metros Label Layers (item 3 — detail)

**New factory file** `src/components/referenceLabelsLayer.ts` with two
`TextLayer` builders mirroring the per-file layer-factory shape:

```
capitalsLayer(data: { name: string; state: string; lat: number; lng: number }[])
metrosLayer(data:   { name: string; lat: number; lng: number; pop: number }[])
```

Shared `TextLayer` config (both):

- `getText: (d) => d.name`, `getPosition: (d) => [d.lng, d.lat]`.
- `getSize` / `sizeUnits: 'pixels'` — capitals `13`, metros `11` (pixel-sized; not
  the rem chrome scale).
- **Halo for legibility over the basemap AND over pins** — `fontSettings: { sdf:
  true }`, `outlineWidth: 2`, `outlineColor: [255, 255, 255, 255]` (a white halo
  that keeps the label readable whether it lands on a light street, a dark park
  polygon, or a colored pin). This is the load-bearing legibility mechanism the
  ui-review gate checks.
- `getColor` — capitals near-black `[40, 40, 40]` (bolder/darker = the more
  important reference tier); metros dark grey `[85, 85, 85]` (`#555` — the muted
  reference tier). Both reuse existing text hues; **no new hex**.
- `fontWeight` — capitals `700` (bold), metros `400` (normal), so the two tiers
  separate by weight as well as size/color.
- Anchor labels ABOVE their point so the dot location is not obscured:
  `getTextAnchor: 'middle'`, `getAlignmentBaseline: 'bottom'`, `getPixelOffset:
  [0, -2]`.
- `pickable: false` (labels are passive; the pins own picking; ZCTA picking is
  MapLibre-native — §6).
- **Labels-only MVP** (per ADR D2) — no per-label dot/`ScatterplotLayer`, no
  `IconLayer` glyph atlas (deferred).

**Clutter control at low zoom (the ui-review legibility gate).** Two layers, two
postures:

- **Capitals** (50, sparse) — render at all zooms; no gating needed.
- **Metros** (~110–180) — gate to avoid a wall of overlapping labels when zoomed
  out. Apply BOTH:
  1. **Min-zoom gate** — omit `metrosLayer` from the overlay array when
     `map.getZoom() < ~5` (the panel toggle being on does not force render below
     the gate). Drive this off the W4 viewport `zoom` already lifted to App
     (`App.tsx:87` viewport), so no new listener.
  2. **Collision filtering** — apply deck.gl's `CollisionFilterExtension` to the
     metros layer (and, when both are on, give **capitals a higher
     `getCollisionPriority`** so a capital label wins a collision against a metro
     — the rationale for capitals being the LAST/top layer in the array). If the
     extension proves heavy, the min-zoom gate alone is the acceptable fallback
     (documented).

**Z-order (load-bearing — labels ABOVE pins).** In the `MapShell` overlay array,
append the label layers **last**, metros then capitals (deck renders bottom→top,
so capitals end up on top):

```
overlay.setProps({ layers: [
  ...(showHeatmap && selectedVertical ? [saturationLayer(cells, trigger)] : []),
  ...(showProspecting && selectedVertical ? [prospectLayer(openCells, trigger)] : []),
  ...(showZones ? [siteZonesLayer(sites, conflictIds)] : []),
  sitePinsLayer(sites, { selectedVertical, filterToVertical }),
  ...(showMetros && zoom >= 5 ? [metrosLayer(metros)] : []),
  ...(showCapitals ? [capitalsLayer(capitals)] : []),
] })
```

Conditional spread (omit when toggled off) preserves the W4 "first paint
byte-identical when all reference toggles off" invariant (`MapShell.tsx:129-149`).
Static JSON is imported once (no fetch); the layers are cheap to rebuild.

---

## 6. ZIP / ZCTA Overlay (item 4 — detail)

**Render mechanism = MapLibre native vector source + style layers** (ADR D1) —
NOT a deck.gl layer. New helper `src/components/zctaSource.ts`:

- `zctaConfigured(): boolean` — `!!import.meta.env.VITE_ZCTA_TILES_URL`.
- `addZctaSource(map)` — on `map.on('load')` (guard `isStyleLoaded()`), add the
  vector source from `VITE_ZCTA_TILES_URL` (PMTiles via the `pmtiles` protocol, or
  a third-party tileset URL) and the two style layers below, **initially
  `visibility: 'none'`**. No-op when `!zctaConfigured()` (no source added, no
  request, no console error — graceful degrade).
- `setZctaVisible(map, on)` — flip `layout.visibility` `'visible'`/`'none'` on
  both layers (cheaper than add/remove). Wired to the `showZcta` toggle.

### Style — subtle so pins/zones/labels stay legible

| Layer | type | key paint | Rationale |
|---|---|---|---|
| `zcta-fill` | `fill` | `fill-color: #6b7280`, `fill-opacity: 0.04` | Near-invisible — its job is to give `queryRenderedFeatures` a hit target for click-to-zip, not to tint the map. Neutral grey (the palette fallback hue), never blue/red/green. |
| `zcta-line` | `line` | `line-color: #6b7280`, `line-opacity: ["interpolate", ["linear"], ["zoom"], 4, 0.25, 8, 0.5]`, `line-width: ["interpolate", ["linear"], ["zoom"], 4, 0.4, 10, 1]` | Subtle neutral boundary lines; thinner/fainter when zoomed out so ~33k boundaries never become a grey mat. Reuses the one new neutral grey `#6b7280` (shared with the palette fallback). |

- **Hover / selected (optional polish):** use MapLibre feature-state to thicken
  the line to `~2px` and raise `fill-opacity` to `~0.08` for the hovered/clicked
  ZCTA — a non-color emphasis cue (width, not hue).
- **Z-order = below pins, automatic.** These are ordinary MapLibre layers; the
  deck.gl overlay (added via `map.addControl`) sits ABOVE all native layers, so
  ZCTA is beneath the wash/zones/pins/labels with no explicit ordering. Insert
  them **beneath the basemap's first symbol (label) layer** (`map.addLayer(...,
  beforeId)`) so the `liberty` place labels still read over the ZCTA lines
  (optional polish; if `beforeId` lookup is brittle across style versions, adding
  on top of the basemap is acceptable since the deck overlay is still above).

### Click → ZCTA code popup

On `map.on('click', e)`: `map.queryRenderedFeatures(e.point, { layers:
['zcta-fill'] })`; read the ZCTA5 id property (`ZCTA5CE20` / `GEOID20` — confirm
at tile-build time and pin the key as a constant in `zctaSource.ts`, per ADR Risk;
fallback: probe for the first 5-digit property). Show a `maplibregl.Popup` at
`e.lngLat` with the zip code:

> ZIP **{zcta5}**

Style minimally via a `.zcta-popup` class (near-black `0.875rem` `600` text on the
default white popup; reuse the panel text hue). Only fire when the ZIP layer is
visible (`showZcta` on) and configured — otherwise the fill is hidden and
`queryRenderedFeatures` returns nothing (no popup), which is the correct silent
no-op.

### Disabled / graceful-degrade state (required — ADR D1)

When `!zctaConfigured()`:

- The **ZIP / ZCTA checkbox is native `disabled`** (never `aria-disabled` — the
  W4 contract), so it is removed from the tab order and SR-announced as dimmed.
- A `.helper-text` note sits directly under it, associated via `aria-describedby`
  on the checkbox input:
  > Configure a ZCTA tile source (`VITE_ZCTA_TILES_URL`) to enable.
- No layout shift, no console error, no broken request. Every other W5 layer
  (capitals, metros, vertical color + filter) works with zero operator setup.

---

## 7. Pin Vertical Filter (item 2 — detail)

One **opt-in** checkbox in the panel: **"Show only this vertical's sites"**
(`filterToVertical`, default **off**). It composes with — never replaces — the
always-on color-by-vertical.

**Behavior:**
- `filterToVertical === false` **OR** `selectedVertical === null` → **all** located
  pins render, each colored by its vertical (the default — full context).
- `filterToVertical === true` **AND** `selectedVertical !== null` → `sitePinsLayer`
  pre-filters `data` to `s.vertical === selectedVertical` (still located); the
  surviving pins keep their palette color (which, since they all share the
  selected vertical, is a single color — that is expected and correct).

**Mechanism** (`sitePinsLayer(sites, { selectedVertical, filterToVertical })`):

```
const visible = (filterToVertical && selectedVertical)
  ? located.filter((s) => s.vertical === selectedVertical)
  : located;
```

Coloring (§4) is applied to `visible` regardless of the filter, so a pin is
**always colored** even when not filtered. App lifts `filterToVertical` alongside
the W4 toggles (`App.tsx:84-90` pattern) and passes it + the already-passed
`selectedVertical` into `MapShell` → `sitePinsLayer`; `MapShell`'s reactive effect
dependency list gains `filterToVertical` (and already has `selectedVertical`) so
the layer rebuilds with the filtered data on toggle.

**Gating:** the checkbox is native `disabled` while `selectedVertical === null`
(filtering to "no vertical" is meaningless) — same gating idiom as the W4
heatmap/prospecting toggles. A `.helper-text` (or the shared "Select a vertical…"
prompt) explains the gate.

**Why one shared control (decided — do not relitigate):** the SAME
`selectedVertical` drives W4 saturation AND this pin filter; there is NO second
vertical dropdown. "The vertical I'm studying" drives the wash and (opt-in) the
pin isolation together.

---

## 8. The Consolidated "Map layers" Panel (item 5 — detail)

Refactor the W4 `SaturationPanel` **in place** (the kickoff is explicit: this is a
refactor, NOT a new panel). Keep the `.saturation-panel` glass shell class (rename
to `.layers-panel` is optional and not required for shipping; renaming touches one
CSS block + one `className` — defer it to avoid churn). Keep the left CRUD panel
untouched. Preserve the W4 a11y contract verbatim: `useId` on every control, the
`aria-live` summary, the numeric saturation legend, native `disabled` for gated
controls.

**Content order, top → bottom:**

1. `<h2>Map layers</h2>` (relabel from "Saturation").
2. **Shared vertical `<select>`** in a `.field` — relabel the visible label
   "Saturation vertical" → **"Vertical"**. Options = "Select vertical…" (`""` →
   `null`) + `VERTICAL_OPTIONS`. This is the single shared control (drives
   saturation AND the pin filter).
3. **"Show only this vertical's sites"** `.field-checkbox` (`filterToVertical`,
   §7) — `disabled` while no vertical selected.
4. `<fieldset class="layers-fieldset">` **Reference layers** (`<legend>`):
   - **State capitals** checkbox (`showCapitals`, default off).
   - **Metro areas** checkbox (`showMetros`, default off).
   - **ZIP / ZCTA boundaries** checkbox (`showZcta`, default off) — native
     `disabled` + the `aria-describedby` helper note when `!zctaConfigured()`
     (§6).
5. `<fieldset class="layers-fieldset">` **Analysis layers** (`<legend>`):
   - **Site zones** checkbox (`showZones`, default **on**) — new toggle for the W3
     zone circles (see Deviation Log: reconciles the kickoff's "Analysis: zones,
     saturation, prospecting" with the ADR lifted-state list).
   - **Saturation heatmap** checkbox (`showHeatmap`, kept) — `disabled` while no
     vertical selected (W4).
   - **Highlight open areas** checkbox (`showProspecting`, kept) — `disabled`
     while no vertical selected (W4).
6. **Vertical color legend** inside `<details><summary>Vertical colors</summary>`
   (collapsible to manage height) — a `.vertical-legend` `<ul>`: one `<li>` per
   `VERTICAL_OPTIONS` row (swatch + the human label) **plus** a final "No
   vertical" row for the neutral fallback. The swatch is `aria-hidden` with a
   dynamic inline `background` (the sanctioned data-driven inline style, exactly
   as the W4 `.sat-legend__swatch`); the **label text is the SR carrier** (never
   color-alone). Shown whenever pins can be colored (i.e., always) — open by
   default is fine; `<details>` lets the operator collapse it.
7. **Saturation legend** (kept, conditional) — the existing `.sat-legend`, shown
   when `selectedVertical !== null` AND (`showHeatmap` OR `showProspecting`)
   (W4 A11Y-001 rule, unchanged).
8. **aria-live summary** (kept) — the `.helper-text aria-live="polite"` saturation
   summary line + computing/cap/empty states (W4, unchanged).
9. **"Jump to nearest open area"** `<button class="btn-secondary">` (kept, W4).

**Keeping it from getting too tall (the explicit kickoff concern):** the panel
already caps at `max-height:70vh; overflow:auto`, so worst case it scrolls — no
content is ever clipped. Mitigate the need to scroll by (a) grouping toggles into
the two compact fieldsets (the `gap:0.25rem` intra-fieldset rhythm is tighter than
the `margin-bottom:1rem` standalone fields), and (b) collapsing the 9-row vertical
color legend into a `<details>`. The two legends (vertical colors, saturation) are
the bulkiest blocks; the saturation legend is already conditional, and the vertical
legend is collapsible — so the steady-state height stays close to the W4 panel.

All new toggle state lifts to App alongside `showHeatmap`/`showProspecting`:
`showCapitals`, `showMetros`, `showZcta`, `showZones` (default true),
`filterToVertical` — same lifted-state pattern (`App.tsx:84-90`), passed to both
the panel (for the controls) and `MapShell` (for the layers); `showZcta` is wired
through `setZctaVisible(map, showZcta)` (MapLibre-native), not the deck array.

---

## 9. States, Keyboard & Screen-Reader Behavior (item 6 — the named ui-review gate)

**Canvas layers are not SR-accessible by nature** (the map is `role="application"`,
W3 A11Y-011). The accessible path for every new map layer is the **panel chrome** —
the toggles (state), the **vertical color legend** (the key for pin coloring), and
the kept W4 saturation legend + aria-live summary. This is the same chrome-scoped
posture as W3/W4.

### Stacked-layer legibility (the gate's core)

- **Label halos** — capitals/metros `TextLayer`s carry a 2px white sdf halo (§5)
  so they read over the basemap, over a colored pin, and over the wash. Capitals
  are bolder/darker than metros (tier separation by weight + color, not color
  alone).
- **ZIP subtlety** — `zcta-fill` is `~0.04` opacity (effectively a click target,
  not a tint); `zcta-line` is a zoom-interpolated faint neutral grey (§6). Pins,
  zones, and the saturation wash stay fully legible above it.
- **Pin color vs zone/saturation** — pins are opaque categorical colors with a 1px
  white stroke ABOVE the translucent zone circles and wash; the palette excludes
  the blue/red/green those layers own, so a pin never reads as a zone, a conflict,
  or a saturation bucket. Worst-case overlap (a `banking` slate pin over the
  darkest `#1558b0` saturation bucket) is separated by the white stroke; the legend
  + filter are the disambiguators.
- **Z-order is the legibility contract** — ZCTA below everything; wash → prospect →
  zones → pins → metro labels → capital labels. Labels last (top); ZIP first
  (bottom).

### Keyboard

- Every control is native — the vertical `<select>`, all checkboxes (filter,
  capitals, metros, ZIP, zones, heatmap, prospecting), and the jump `<button>`:
  Tab to focus, native activation (arrows/type-ahead on the select; Space toggles
  checkboxes; Enter/Space the button). All inherit the global `:focus-visible`
  (`2px #1a73e8`, 2px offset) — do NOT override.
- `<fieldset>`/`<legend>` groups the toggles for SR navigation; `<details>`/
  `<summary>` is natively keyboard-operable (Enter/Space toggles the legend
  disclosure).
- Disabled controls (ZIP when unconfigured; filter/heatmap/prospecting when no
  vertical) use the native `disabled` attribute — removed from the tab order, SR
  "dimmed". **No `aria-disabled` divs.**
- No `<div onClick>`; the ZCTA click-to-zip is a **mouse map interaction** with no
  keyboard equivalent — this is an accepted limitation of the `role="application"`
  canvas (consistent with W3/W4), and is NOT the accessible carrier of any
  required information (the popup is an exploratory enhancement; the zip lookup is
  not a task gate).

### Screen reader

- Every new control has a `<label htmlFor={useId()}>`; the two fieldsets have a
  `<legend>`; the ZIP disabled note is tied via `aria-describedby` — no orphan
  controls, no unexplained disabled state.
- Legend swatches (both legends) are `aria-hidden`; the **real text label is the
  announced carrier** (never color-alone) — the vertical legend names each vertical
  ("Gas / convenience", … "No vertical"); the saturation legend names each bucket
  ("1 zone", …).
- The kept aria-live summary stays `aria-live="polite"` and seeded-empty when no
  vertical is selected (W4 A11Y-002, unchanged); the static "Select a vertical…"
  prompt stays non-live. Nothing in this read-only view uses `role="alert"`.
- The map canvas stays `role="application"` with its `aria-label`; W5 layer a11y is
  fully carried by the panel chrome.

### Color contrast

- All panel text (near-black, `#555`) clears AA (≥4.5:1) on white.
- Every `VERTICAL_COLORS` fill clears 3:1 graphical on white (§4 table, min
  ~4.5:1); each is reinforced by the `#555`-bordered legend swatch + its real text
  label.
- Capitals `[40,40,40]` / metros `[85,85,85]` map labels clear AA against the
  basemap by virtue of the white halo (the halo guarantees a light backing
  regardless of the underlying pixel); the halo is the legibility mechanism, not a
  contrast shortcut.
- `zcta-line` `#6b7280` is a decorative boundary (not text, not a required
  graphical distinction) — its subtlety is intentional; the click popup (near-black
  text) is the accessible ZCTA-code carrier.
- The `#1a73e8` focus ring is the non-text 3:1 component color (do not "fix" it —
  W2 F-002).

### Loading / empty (kept + new)

- Saturation computing/cap/empty states: unchanged from W4 (the kept aria-live
  summary).
- ZIP unconfigured: the disabled toggle + helper note (§6) — the panel's only new
  "unavailable" state; never a silent missing feature.
- Capitals/metros: static — no loading state; toggles take effect immediately.
- Metros below the min-zoom gate: the toggle stays checked but the layer is
  omitted; this is intentional clutter control, not an error — no notice needed
  (the labels reappear on zoom-in).

---

## 10. Anti-Patterns (Do NOT do)

- No Tailwind utilities / `bg-*`/`text-*` / CSS variables — plain semantic CSS
  classes + literal hex only. Add `.layers-fieldset`, `.vertical-legend`,
  `.zcta-popup` to `src/index.css`; reuse `.saturation-panel`, `.sat-legend*`,
  `.field*`, `.helper-text`, `.btn-secondary`.
- No second vertical dropdown — ONE shared `selectedVertical` drives saturation AND
  the pin filter (decided; do not relitigate).
- No new floating panel — refactor the W4 `SaturationPanel` in place; the left CRUD
  `.site-panel` is untouched.
- No vertical color that collides with the reserved semantics — never reuse
  conflict-red `#b00020`, the saturation Blues (`#c6dbef`/`#6baed6`/`#1558b0`), or
  prospect-green `#137333` for a `VERTICAL_COLORS` entry.
- No vertical signalled by **color alone** — the vertical color legend (real text
  per row) + the opt-in single-vertical filter are the authoritative carriers; the
  pin color is orientation/reinforcement.
- No translucent / alpha pin fill — pins stay opaque so they read crisply over the
  wash and zones (the white stroke is the separation cue).
- No map label without a halo — capitals/metros MUST carry the white sdf halo
  (legibility over basemap + pins is the named gate).
- No rendering ~180 metro labels at low zoom — apply the min-zoom gate (+ collision
  filtering); do not flood the map.
- No deck.gl `MVTLayer` for ZCTA — use the MapLibre native vector source (ADR D1:
  click-picking + "below pins" for free).
- No tinting the map with the ZCTA fill — keep `fill-opacity ~0.04` (a click
  target, not a wash); keep the line subtle/zoom-interpolated.
- No hardcoded tile token/URL — the ZCTA source is `VITE_ZCTA_TILES_URL` only
  (rules-security; token rides in the env var, never committed).
- No broken/disabled-state hack for an unconfigured ZCTA — native `disabled`
  checkbox + `aria-describedby` helper note; no console error, no layout shift.
- No `aria-disabled` divs for any gated toggle — use the native `disabled`
  attribute (filter/heatmap/prospecting when no vertical; ZIP when unconfigured).
- No `<div onClick>`; every chrome control is a real `<select>`/`<input>`/
  `<button>`; `<details>`/`<summary>`/`<fieldset>`/`<legend>` for grouping.
- No removing/weakening the global `:focus-visible` outline; no per-element focus
  override.
- No mounting labels below pins or ZCTA above pins — labels LAST in the deck array
  (top); ZCTA as MapLibre-native (bottom).
- No rendering an empty reference layer when its toggle is off — omit it from the
  array (preserve the W4 byte-identical-first-paint invariant).
- No inline `style={{…}}` in TSX beyond the sanctioned legend-swatch `background`
  (dynamic per-row, exactly as W4) and the `MapShell` canvas `inset` style.
- No re-authoring `VERTICAL_OPTIONS` — import and reuse it; `VERTICAL_COLORS` keys
  on the same tokens.

---

## 11. Reference Patterns

Codebase north-star files — read before implementing; they ARE the quality bar:

- `src/components/SaturationPanel.tsx` — the panel being refactored: the `useId`
  label pattern, the `.field` / `.field-checkbox` idiom, the conditional legend,
  the `aria-live` summary, native `disabled` gating, the seeded-empty live region.
  **Extend this; do not rewrite its W4 logic.**
- `src/components/sitePinsLayer.ts` — the `ScatterplotLayer` factory to extend with
  the palette `getFillColor` + the optional filter (the located-filter pattern
  stays).
- `src/components/siteZonesLayer.ts` — the `updateTriggers` + `conflictKey` stable-
  key idiom (mirror it if a `getFillColor` trigger is wanted) and the per-datum
  RGBA-accessor shape.
- `src/components/saturationLayer.ts` — the deck.gl factory shape to mirror for the
  `TextLayer` builders in `referenceLabelsLayer.ts`.
- `src/components/MapShell.tsx` — the reactive `overlay.setProps({layers:[…]})`
  seam + the conditional-spread z-order (`:129-149`) to extend with the labels
  (last) and the pin-filter props; the `map.on('load')` / `isStyleLoaded()` guard
  pattern to mount the ZCTA native source; the `role="application"` canvas posture.
- `src/App.tsx` — the lifted-state pattern (`:84-90`) for `showCapitals` /
  `showMetros` / `showZcta` / `showZones` / `filterToVertical`; the viewport `zoom`
  already lifted (`:87`) drives the metros min-zoom gate.
- `src/lib/customers.ts` — `VERTICAL_OPTIONS` + `verticalLabel()` (import; do not
  re-author); `VERTICAL_COLORS` in the new `verticalStyle.ts` keys on the same
  tokens.
- `src/index.css` — `.saturation-panel` / `.sat-legend*` / `.field*` /
  `.helper-text` / `.btn-secondary` and the literal-hex palette. Add
  `.layers-fieldset` / `.vertical-legend` / `.zcta-popup` here in the same style.

No external dashboard north-star — this is a deliberately minimal plain-CSS app;
the W1–W4 files are the standard.

---

## Deviation Log

| Area | What was missing / divergent in spec/ADR | Default applied |
|---|---|---|
| Per-vertical palette values | The ADR (D3) names `VERTICAL_COLORS` as a stable `[r,g,b]` palette + neutral fallback but does not fix the hex values. | Defined an 8-color categorical palette + neutral fallback (§4), each ≥3:1 graphical on white, deliberately avoiding conflict-red / saturation-blue / prospect-green. Stated the closest pair (gas/automotive, separated by lightness) and named the legend + filter as the accessible disambiguators (color-by-vertical = orientation, not identity). |
| Site-zones toggle | The kickoff's decided context lists the **Analysis** section as "zones, saturation, prospecting"; the ADR's lifted-state list (D4) enumerates only `showCapitals`/`showMetros`/`showZcta`/`filterToVertical` (zones stay always-on). | Added a **"Site zones"** toggle (`showZones`, default **on**) to the Analysis fieldset per the kickoff's decided section contents — additive (conditionally spread `siteZonesLayer`), no W3/W4 logic change, preserves first-paint. |
| Capitals vs metros label tiering | ADR D2 says "muted reference grey" for both; the two tiers need to separate. | Capitals = bolder/darker near-black `[40,40,40]` `13px`; metros = `#555`-grey `[85,85,85]` `11px` normal. Both carry a white sdf halo. Tier separation by size + weight + color, not color alone. |
| Metro clutter control | ADR Risk says "collision filtering / min-zoom gating for metros" without picking. | Applied BOTH: a min-zoom gate (omit metros below z≈5, driven off the already-lifted viewport zoom) AND `CollisionFilterExtension` with capitals given higher collision priority; min-zoom alone is the documented fallback if the extension is heavy. |
| ZCTA fill/line exact style | ADR D1 says "near-transparent fill + visible line stroke" without values. | `zcta-fill` neutral grey `#6b7280` at `0.04` opacity (a click target, not a tint); `zcta-line` `#6b7280` zoom-interpolated opacity `0.25→0.5` and width `0.4→1px`. One new neutral grey, shared with the palette fallback. Optional feature-state hover thickening. |
| ZCTA id property name | ADR Risk: varies by tileset (`ZCTA5CE20` vs `GEOID20`). | Pin the property key as a constant in `zctaSource.ts` confirmed at tile-build time; fallback probes for the first 5-digit property. The popup reads it as the displayed zip. |
| ZCTA keyboard a11y | The click-to-zip is a mouse map interaction with no keyboard path. | Documented as an accepted `role="application"` canvas limitation (consistent with W3/W4); the popup is an exploratory enhancement, not a required-information carrier — so no SR/keyboard equivalent is mandated. |
| Vertical legend height | The panel gains a 9-row vertical legend on top of the existing saturation legend. | Wrapped the vertical color legend in `<details><summary>Vertical colors</summary>` (collapsible) and grouped toggles into two compact fieldsets; the existing `max-height:70vh; overflow:auto` is the backstop. |
| Component / class rename | ADR D4 says renaming `SaturationPanel` → `LayersPanel` (and the class) is optional. | Kept the component + `.saturation-panel` shell class to minimize churn and preserve the W4 a11y wiring; only the visible heading text changes to "Map layers". Rename is a safe later cosmetic pass. |
| Responsive layout | Two floating panels (22rem left + 18rem right), now with a taller right panel. | No responsive collapse this wave (desktop tool, per W2/W4); the right panel scrolls within `70vh`. Flagged for a future pass if mobile enters scope. |
