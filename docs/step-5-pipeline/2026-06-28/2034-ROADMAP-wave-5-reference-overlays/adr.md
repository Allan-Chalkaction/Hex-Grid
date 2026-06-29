# ADR-005: Reference Overlays — Self-Hosted/Configurable ZCTA Vector Tiles via MapLibre Native Source (Operator Dependency); Embedded Static Capitals+Metros JSON → deck.gl Label Layers; One Shared Map-Vertical Control; Single Consolidated Layers Panel; No Migration

**Status:** Proposed
**Date:** 2026-06-28
**Feature:** reference-overlays (Wave 5)
**Spec:** docs/step-3-specs/hex-grid/waves/reference-overlays/reference-overlays.md
**Builds on:** ADR-001 (foundation), ADR-002 (customers-geocoding), ADR-003 (exclusivity-engine W3), ADR-004 (area-saturation W4)

## Context

Wave 5 adds *reference* context to the map: state-capital + metro labels, a toggleable ZIP/ZCTA overlay ("click a box, see the zip"), per-vertical site-pin filtering/coloring, and a layer-toggle UI. It is **independent of W2–W4 tenant data** — every new layer is either static-bundled or external, and the only tenant read it adds is a filter over the already-loaded `site_geo`.

Built substrate that constrains the decisions:
- **Basemap is MapLibre native vector** — OpenFreeMap `liberty` style, **no API key** (`MapShell.tsx:76`). Adding a native vector *source* is idiomatic and gives `queryRenderedFeatures` click-picking for free.
- **deck.gl overlay is a persisted `MapboxOverlay`** whose layer array is rebuilt reactively on data change, with a **load-bearing z-order** and conditional spread so first paint is byte-identical when toggles are off (`MapShell.tsx:129-149`).
- **`selectedVertical` is already lifted in App** (`App.tsx:84`) and drives W4 saturation through the floating `SaturationPanel` (top-right, glass treatment — `SaturationPanel.tsx`, `index.css:363`).
- **`VERTICAL_OPTIONS` / `verticalLabel`** is the controlled 8-token vocabulary (`customers.ts:70-88`); `site_geo.vertical` is built (W3) and already on every loaded row.
- Layer factories follow one shape: `src/components/<x>Layer.ts` builds a deck.gl layer from data (`sitePinsLayer.ts`, `siteZonesLayer.ts`, `saturationLayer.ts`). `deck.gl` umbrella re-exports geo/text layers.

The ZCTA source is **the one decision CC cannot fully resolve itself** — there is no robust, stable, free, key-less, hosted ZCTA vector-tile endpoint. This drives an explicit operator dependency, designed to degrade gracefully.

## Decision

Add reference overlays as **read-only, additive** layers: **(1)** a configurable/self-hosted **ZCTA vector tileset rendered as a MapLibre native source** (operator dependency; graceful-degrade when unset); **(2)** **static embedded JSON** for capitals+metros → deck.gl label layers; **(3)** **one shared `selectedVertical`** that drives both saturation and an opt-in pin filter, with always-on color-by-vertical; **(4)** **one consolidated top-right "Map layers" panel**; **(5) no migration**.

### Decisions list (load-bearing)

1. **ZCTA = MapLibre native vector source** from a **configurable URL** (`VITE_ZCTA_TILES_URL`), default a **self-hosted PMTiles** archive built from Census TIGER ZCTA5. Absent → ZIP toggle hidden/disabled. **Operator dependency — flagged.** (D1)
2. **Capitals (50) + metros (CBSA ≥250k, ~110-180)** = static `src/data/*.json` → deck.gl `TextLayer` label factories. (D2)
3. **One shared `selectedVertical`** (the existing App state) drives saturation AND pins; **color-by-vertical is always-on**; **pin filtering is an opt-in checkbox** — no second vertical dropdown. (D3)
4. **One consolidated top-right panel** (rename `SaturationPanel` heading → "Map layers"; add a "Reference layers" fieldset + the filter checkbox). No new floating panel, no W4 logic rewrite. (D4)
5. **No migration 0005-equivalent.** Reference data is static/external; `vertical` already on `customer`/`site_geo`. (D5)

### Component Structure
```
src/
  data/
    capitals.json          # 50 state capitals — ~4 KB
    metros.json            # CBSA >=250k (~110-180) — ~15-20 KB
  lib/
    verticalStyle.ts       # VERTICAL_COLORS: stable [r,g,b] per VERTICAL_OPTIONS token + neutral fallback
  components/
    referenceLabelsLayer.ts  # capitalsLayer() / metrosLayer() — deck.gl TextLayer factories
    zctaSource.ts            # addZctaSource(map) / setZctaVisible(map,on) / zctaConfigured() — MapLibre native source helpers
    MapShell.tsx           # (edit) accept reference props; mount ZCTA native source; extend deck array + z-order
    sitePinsLayer.ts       # (edit) signature -> sitePinsLayer(sites, { selectedVertical, filterToVertical }) — color + opt filter
    SaturationPanel.tsx    # (edit) add Reference-layers fieldset + filter checkbox; relabel heading "Map layers"
    App.tsx                # (edit) lift showCapitals/showMetros/showZcta/filterToVertical
```

### Data Model / Migration
**None.** No new table, view, column, RPC, RLS policy, or index. `db-migration-reviewer` gate not required (matches the skeleton's gates: code-reviewer · ui-review).

### D1 — ZCTA vector tiles: MapLibre native source, configurable URL, operator dependency (THE load-bearing call)

**Rejected: full ZCTA GeoJSON client-side (~33k polygons).** Unsimplified TIGER ZCTA5 is hundreds of MB; even aggressively simplified it is tens of MB to download + parse, and a 33k-polygon `GeoJsonLayer` would stall the main thread. Vector tiles exist precisely to serve only the polygons in the current viewport at the current zoom — the correct primitive.

**Render mechanism = MapLibre native vector source + fill/line style layers, NOT a deck.gl `MVTLayer`.** Rationale: the basemap is already MapLibre vector, so a native source is idiomatic; it gets GPU tile rendering and **`map.queryRenderedFeatures()` click-picking for free** (the click-to-see-zip interaction); and it keeps the deck.gl overlay reserved for data-driven layers. The ZCTA fill/line sit **beneath the deck.gl overlay** (overlaid mode = deck canvas on top), which is exactly the requested "ZIP below pins" without any explicit ordering work.

**Source = a configurable URL with a self-hosted default.** There is **no robust free key-less hosted ZCTA vector-tile endpoint**. The two viable robust options both need an operator action, so the design makes the source a config point:
- `VITE_ZCTA_TILES_URL` env var. **Default (recommended): a self-hosted PMTiles archive** generated once from Census TIGER `tl_2020_us_zcta520` (tippecanoe → `zcta.pmtiles`), uploaded to a **Supabase Storage public bucket** (supports HTTP Range, which PMTiles requires) and read via the `pmtiles` MapLibre protocol. One-time build, no recurring key, no per-tile cost.
- **Alternative:** point the env var at a third-party ZCTA tileset (e.g. a Mapbox/Maptiler boundaries-postal tileset). **Token discipline (rules-security):** any token rides in the configured URL via env var — **never hardcoded**, never committed.

**Operator dependency — FLAGGED:** CC cannot fabricate or host a tileset. **The ZCTA overlay ships dark by default.** Until an operator (a) generates+hosts the PMTiles or (b) supplies a tileset URL/token via `VITE_ZCTA_TILES_URL`, the feature must degrade gracefully.

**Graceful degradation (required):** `zctaConfigured()` returns false when the env var is unset → the ZIP toggle renders **disabled** with helper text "Configure a ZCTA tile source (VITE_ZCTA_TILES_URL) to enable." No console error, no broken request, no layout shift. Every other Wave 5 layer (capitals, metros, vertical filter) works with zero operator setup.

**Click-to-see-zip:** on `map.on('click', e)`, `map.queryRenderedFeatures(e.point, { layers: ['zcta-fill'] })`; read the ZCTA5 id property (`ZCTA5CE20` / `GEOID20`, depending on the built tileset — confirm at tile-build time) → show a `maplibregl.Popup` at the click point with the zip code. The fill is near-transparent with a visible line stroke so the basemap reads through; hover/selected feature-state can thicken the outline (optional polish).

**Mount:** add the source + fill/line layers on `map` once the style is loaded (`map.on('load')` / guard `isStyleLoaded()`), inserted **below** the first deck layer (i.e. as ordinary MapLibre layers — they are already under the overlay). The toggle flips the layers' `visibility` layout property (cheaper than add/remove).

**Recommended mitigation (operator-setup friction):** ship the self-hosted PMTiles default + a short `docs/` build note (tippecanoe command + upload step). **Alternative if no hosting is acceptable:** disabled toggle + helper text is the permanent graceful state — the wave still ships its other three layers.

### D2 — Capitals + metros: static embedded JSON → deck.gl TextLayer

Bundle two small static files (no fetch, no key, no migration):
```jsonc
// src/data/capitals.json  (~50 rows, ~4 KB)
[{ "name": "Sacramento", "state": "CA", "lat": 38.5767, "lng": -121.4934 }]
// src/data/metros.json   (~110-180 rows, ~15-20 KB)
[{ "name": "Los Angeles", "lat": 34.05, "lng": -118.24, "pop": 13200000 }]
```
Combined < ~25 KB gzipped-trivial — fine to bundle. **Source note:** capitals are public/static (state capital coordinates); the metro list derives from the **Census CBSA delineation (2020 vintage) filtered to total population ≥ 250k (2020 estimates)** — record the vintage in a header comment in `metros.json` so the list is reproducible. Both are reference geography, not tenant data, so static embedding is correct (no staleness concern beyond a decennial refresh).

Render via `referenceLabelsLayer.ts`: `capitalsLayer(data)` and `metrosLayer(data)` build deck.gl `TextLayer`s (`getText: d => d.name`, `getPosition: [lng,lat]`, pixel-sized font, `getColor` a muted reference grey, optional collision/`getTextAnchor`). A small dot per label is optional (a thin `ScatterplotLayer`); recommend **labels-only MVP** to keep the surface minimal. Icon glyphs are deferred (an IconLayer needs an atlas — heavier; not warranted for reference points).

### D3 — Vertical filtering + color-by-vertical: ONE shared control (reconciliation)

**Reconciliation (avoid two competing vertical controls):** reuse the **single existing `selectedVertical`** lifted in App — do **not** add a second vertical dropdown. The existing `SaturationPanel` dropdown becomes the **shared map-vertical control** (relabel "Saturation vertical" → "Vertical"). Split the two concerns it now serves:

- **Color-by-vertical = always-on visual encoding, no control.** Every site pin is colored by its `vertical` via a **stable palette** `VERTICAL_COLORS` (a `Record<token,[r,g,b]>` over the 8 `VERTICAL_OPTIONS` tokens + a neutral grey for `null` vertical), defined in `src/lib/verticalStyle.ts` next to the vocabulary it keys on. Pins always carry orientation regardless of selection. A swatch legend lives in the panel.
- **Filter-by-vertical = opt-in checkbox.** A single "Show only this vertical's sites" checkbox (in the same panel). When checked **and** a vertical is selected, `sitePinsLayer` pre-filters `data` to that vertical; otherwise all pins show (still colored). Filtering is opt-in so saturation can be studied for one vertical **without** losing context pins of others.

Mechanism: `sitePinsLayer(sites, { selectedVertical, filterToVertical })` — `getFillColor: d => VERTICAL_COLORS[d.vertical ?? ''] ?? NEUTRAL`, with an `updateTriggers.getFillColor` stable key (mirrors `siteZonesLayer`'s `conflictKey` idiom) and `data` filtered when `filterToVertical && selectedVertical`. App lifts `filterToVertical` alongside the W4 toggles; pass it + `selectedVertical` (already passed) into `MapShell` → `sitePinsLayer`.

**Why shared, not independent:** two vertical pickers (one for saturation, one for pins) is the panel-proliferation anti-pattern the kickoff calls out — they would drift and confuse. One vertical means "the vertical I'm studying," and both the wash and the (optional) pin isolation follow it.

### D4 — Layer-toggle UI: one consolidated panel (no W4 rewrite)

**One panel governs all toggles.** Extend the existing floating top-right `SaturationPanel` rather than adding a third floating surface (the left CRUD `.site-panel` stays untouched). Concretely:
- Relabel the panel heading "Saturation" → **"Map layers"**.
- Add a **"Reference layers"** `<fieldset>` with three checkboxes: **State capitals**, **Metro areas**, **ZIP / ZCTA boundaries** (the ZIP checkbox `disabled` + helper text when `!zctaConfigured()` — D1).
- Add the **"Show only this vertical's sites"** checkbox (D3) near the shared vertical dropdown.
- Keep the existing Saturation section (vertical select, heatmap, prospecting, legend, jump) intact — purely additive markup, **no W4 logic change**. (Optionally rename the component to `LayersPanel`; not required for shipping.)

All new toggle state lifts to App alongside `showHeatmap`/`showProspecting`: `showCapitals`, `showMetros`, `showZcta`, `filterToVertical` (same lifted-state pattern, `App.tsx:84-90`). Reuse existing `.field-checkbox` / `.helper-text` / glass styles (`index.css:363`); the only new CSS is a vertical-color swatch legend (mirror `.sat-legend`).

**Mount / z-order (legibility — labels above pins, ZIP below pins):**
- **MapLibre native (bottom):** basemap → `zcta-fill` → `zcta-line` (reference, beneath the whole deck overlay).
- **deck.gl overlay array (first = bottom):** `[ saturationLayer?, prospectLayer?, siteZonesLayer, sitePinsLayer, metrosLayer?, capitalsLayer? ]`. Labels appended **last** so they render **above** pins/wash (legibility); capitals after metros so a capital label wins a collision. All reference layers conditionally spread (omitted when toggled off), preserving the W4 "first paint byte-identical when off" invariant (`MapShell.tsx:129-149`).

### D5 — Migration shape

**NONE.** Capitals/metros are bundled static JSON; ZCTA is external/self-hosted tiles consumed by the basemap library; `vertical` is already on `customer` and surfaced in `site_geo` (W3). No table/view/column/RPC/RLS/index. No `db-migration-reviewer` gate.

## Consequences

### Benefits
- Zero new migration, zero new RLS surface; the only tenant read is an in-memory filter over already-RLS-scoped `site_geo`. Lowest-risk posture.
- ZCTA as a MapLibre native source reuses the existing vector basemap, gets click-picking for free, and keeps "ZIP below pins" automatic; the deck.gl overlay stays reserved for data layers.
- One shared vertical + one consolidated panel kills the two-control / panel-proliferation anti-pattern; color-by-vertical adds orientation with no extra control.
- Reuses every established pattern: per-file layer factory, reactive conditional-spread overlay, lifted state, the `VERTICAL_OPTIONS` vocabulary, env-var token discipline.

### Tradeoffs
- ZCTA requires a one-time operator action (host PMTiles or supply a URL); it ships dark until then. Accepted — flagged + graceful-degrade.
- Metro list is a point-in-time snapshot (2020 vintage); a decennial refresh is a JSON edit, not a code change.
- Color-by-vertical first; per-vertical glyph icons deferred.

### Risks
- **ZCTA never configured → feature looks missing.** **Recommended mitigation:** ship the self-hosted PMTiles default + a build note, and a clear disabled-toggle helper string so the gap is self-explanatory. **Alternative if hosting is declined:** the disabled toggle is the permanent graceful state; the other three layers still ship.
- **ZCTA property name varies by tileset** (`ZCTA5CE20` vs `GEOID20`). **Recommended mitigation:** read the property at tile-build time and pin it in `zctaSource.ts`; for a third-party tileset, make the property key a small constant to adjust. **Alternative:** probe `feature.properties` for the first 5-digit key.
- **Label clutter at low zoom** (~180 metros + 50 capitals). **Recommended mitigation:** `TextLayer` collision filtering / min-zoom gating for metros; ui-review confirms stacked-layer legibility (the named gate).
- **Pin recolor not re-evaluating.** Mitigation: `updateTriggers.getFillColor` stable key (the `conflictKey` idiom).

## Implementation Notes

### Migration Safety
- None (D5). Nothing to reverse, backfill, or deploy DB-side.

### Testing Strategy
- **Unit:** `sitePinsLayer` colors by vertical (each token → its palette entry; null → neutral); `filterToVertical && selectedVertical` filters data, else passes all. `zctaConfigured()` true/false off the env var. capitals/metros JSON parse to the expected shape/counts.
- **Integration:** toggling each reference layer adds/removes its layer; ZIP toggle disabled when unconfigured; selecting a vertical drives both wash and (when filter on) pins from the one control.
- **Manual / ui-review:** stacked-layer legibility (labels above pins, ZIP fill reads through, wash under all); click a ZCTA → popup shows the zip; first paint byte-identical with all reference toggles off.

### Performance Considerations
- ZCTA rendering is GPU/tile-native (viewport-bounded by construction) — no client polygon set.
- Label layers are static (~230 points) — built once; conditional spread keeps them out of the array when off.
- Pin filter/color is an in-memory pass over the already-loaded set; `updateTriggers` keyed, never per-frame.

## Alternatives Considered

### deck.gl MVTLayer for ZCTA (instead of MapLibre native source)
Rejected. Would route click-picking through deck and duplicate the vector-tile story the basemap already owns; native source gives `queryRenderedFeatures` + "below pins" for free. MVTLayer remains a fallback if interleaving requirements change.

### Full ZCTA GeoJSON client-side
Rejected (D1) — ~33k polygons, tens of MB, main-thread stall. Vector tiles are the right primitive.

### Second independent vertical control for pins
Rejected (D3) — two vertical pickers drift and confuse (the panel-proliferation anti-pattern). One shared vertical + opt-in filter + always-on color.

### Separate floating "Layers" panel
Rejected (D4) — a third floating surface crowds the map; folding into the existing top-right panel is additive and avoids a W4 rewrite.

## Spec Issues Found

### Blockers (must fix before implementation)
- **None — but one explicit operator dependency.** Every read has a source: pins from `site_geo` (built), `vertical` from `site_geo.vertical` (built W3), capitals/metros from in-scope bundled JSON. **The ZCTA tileset has no in-repo source and cannot be fabricated by CC** — it is an **operator dependency** (`VITE_ZCTA_TILES_URL` → self-hosted PMTiles or a third-party tileset). This is *not* a blocker because the overlay is designed to degrade gracefully (disabled toggle); but the ZIP "click a box, see the zip" capability does not function until the operator configures a source.

### Recommendations (should fix)
- pm-spec should make **"generate + host the ZCTA PMTiles (or supply a tileset URL)"** an explicit operator-setup atom with the tippecanoe build note, separate from the code atoms, so the dependency is tracked rather than implied.
- Name **`verticalStyle.ts` (the stable palette)** and the **`sitePinsLayer` signature change** as explicit atoms — they are shared surfaces, not implicit refactors.
- Confirm the ZCTA id property name at tile-build time and pin it in `zctaSource.ts`.

### Notes (FYI for implementer)
- Mount order is load-bearing: MapLibre `zcta-fill/line` below the overlay; deck array labels LAST (above pins), wash/zones/pins per W4.
- Reuse `VERTICAL_OPTIONS` for the legend rows — do not re-author the vocabulary.
- Cross-wave seam: Wave 5 only *reads* the stable `site_geo` contract + adds reference layers; read-only, additive, no W2-W4 source change. Standalone single-wave `/orchestrated` build — no `crossWavePrior`, architect-final not required.
