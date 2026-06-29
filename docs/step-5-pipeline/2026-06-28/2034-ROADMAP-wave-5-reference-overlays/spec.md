# Feature Spec: Reference Overlays (Wave 5)

**Status:** Draft
**Author:** AI-assisted (pm-spec agent, funnel integrator)
**Date:** 2026-06-28
**Slug:** reference-overlays
**Ticket key:** HGW-5
**ADR:** ADR-005 (docs/step-5-pipeline/2026-06-28/2034-ROADMAP-wave-5-reference-overlays/adr.md)
**UI Spec:** ui-spec-addendum.md (same run folder)
**CTO verdict:** SIMPLIFY (GO, trimmed) — all four features build now; ZIP degrades gracefully.

## Summary

Wave 5 adds *reference context* to the hex-grid map: state-capital + metro labels, a toggleable ZIP/ZCTA boundary overlay ("click a box, see the zip"), per-vertical site-pin coloring + an opt-in single-vertical filter, and a single consolidated layer-toggle panel. Every new layer is read-only and additive — static-bundled JSON, an external/self-hosted vector tileset, or an in-memory pass over the already-loaded `site_geo`. It is independent of W2–W4 tenant *data* but extends the W3/W4 map + panel surface; no migration, no DB surface.

## User Stories

- As an operator, I want every site pin colored by its vertical (always-on) with a legend, so I can read the vertical mix at a glance without selecting anything.
- As an operator, I want to optionally show only the sites of the vertical I'm studying, so I can isolate one vertical without losing the always-on coloring for the rest when I turn it off.
- As an operator, I want state-capital and metro labels on the map so I can orient on geography without external reference.
- As an operator, I want to toggle a ZIP/ZCTA boundary overlay and click a boundary to see its zip code, so I can reason about coverage by postal area.
- As an operator without a configured ZCTA tile source, I want the ZIP toggle to be clearly disabled with an explanation rather than silently broken, so I know the feature exists and how to enable it.
- As an operator, I want one panel that governs all map layers (reference + analysis) so the controls don't proliferate across competing surfaces.

## Acceptance Criteria

ACs are testable. Verification biases toward vitest (deck.gl layers + MapLibre style objects construct without a GL context, so their props are inspectable in the node env — see `src/components/saturationLayer.test.ts`); canvas/map-render and operator-dependent paths carry precise manual notes. AC-NNN identifiers are stable; downstream agents reference them by ID.

### Per-vertical palette (`verticalStyle.ts`)

- [ ] **AC-001.** Substantive: a stable per-vertical color palette exists keyed on the 8 `VERTICAL_OPTIONS` tokens with a neutral fallback for `null`/unknown, and the color for a given token never changes between renders/sessions. Verification: vitest — `import { VERTICAL_COLORS, VERTICAL_NEUTRAL } from src/lib/verticalStyle.ts`; assert every `VERTICAL_OPTIONS` token has an entry, each entry is an `[r,g,b]` triple, and `VERTICAL_NEUTRAL` equals `[107,114,128]`. The map is a module-level const (stability by construction).

- [ ] **AC-002.** Substantive: no `VERTICAL_COLORS` entry (nor the neutral) collides with the three reserved semantic colors — conflict-red `[176,0,32]`, the saturation Blues `[198,219,239]`/`[107,174,214]`/`[21,88,176]`, or prospect-green `[19,115,51]`. Verification: vitest — assert no palette value (incl. neutral) deep-equals any reserved triple (enumerate the reserved set as a fixture).

- [ ] **AC-003.** Substantive: looking up an unknown or `null` vertical yields the neutral fallback, never `undefined`. Verification: vitest — `VERTICAL_COLORS[d.vertical ?? ''] ?? VERTICAL_NEUTRAL` returns the neutral for `''`, `null`, and an unlisted token; returns the token's color for each listed token.

### Site-pin coloring + filter (`sitePinsLayer.ts`)

- [ ] **AC-004.** Substantive: every located site pin is colored by its vertical via the palette regardless of selection or filter state. Verification: vitest — build `sitePinsLayer(sites, { selectedVertical: null, filterToVertical: false })` over fixture sites of mixed verticals (incl. a `null`); read `layer.props.getFillColor` per datum (or evaluate the accessor) and assert each equals its palette color / neutral. The fill is opaque (3-tuple, no alpha — mirrors the current `[21,88,176]`).

- [ ] **AC-005.** Substantive: when `filterToVertical` is on AND a vertical is selected, only that vertical's located sites render; otherwise all located sites render. Verification: vitest — over fixture sites: (a) `{filterToVertical:true, selectedVertical:'gas'}` → `layer.props.data` contains only `gas` located sites; (b) `{filterToVertical:false, selectedVertical:'gas'}` → all located sites; (c) `{filterToVertical:true, selectedVertical:null}` → all located sites. The pre-existing `lat!=null && lng!=null` located-filter is preserved in every case.

- [ ] **AC-006.** Substantive: the recolor/refilter re-evaluates when inputs change and is never recomputed per frame. Verification: vitest — confirm `id: 'site-pins'` unchanged; if an `updateTriggers.getFillColor` key is present it is a constant (`'vertical-palette-v1'`), never a per-call/per-frame value. (Redraw is driven by the layer rebuild on `sites`/`selectedVertical`/`filterToVertical` change — AC-013.)

### Capitals + metros data + label layers

- [ ] **AC-007.** Substantive: `src/data/capitals.json` is the 50 US state capitals, each with `{name, state, lat, lng}`. Verification: vitest — import the JSON; assert `length === 50`, every row has the four keys with correct types, `lat`/`lng` are finite and within CONUS-plus-AK/HI bounds, and `state` values are 50 unique 2-letter codes.

- [ ] **AC-008.** Substantive: `src/data/metros.json` is the CBSA list filtered to total population ≥250k (2020 vintage recorded in a header/source comment), each with `{name, lat, lng, pop}`. Verification: vitest — import the JSON; assert `length` in [110,180], every row has the four keys with correct types, every `pop >= 250000`, `lat`/`lng` finite. (Vintage note lives in a sibling `.md`/source comment since JSON has no comments — assert a `metros.source.md` or equivalent provenance file exists, OR a leading `_meta` row records the vintage.)

- [ ] **AC-009.** Substantive: `capitalsLayer(data)` and `metrosLayer(data)` build deck.gl `TextLayer`s that render the place name at its position with a white sdf halo (the legibility mechanism), labels anchored above their point, and `pickable:false`. Verification: vitest — build each layer over a fixture row; assert `layer instanceof TextLayer`, `getText` yields `d.name`, `getPosition` yields `[lng,lat]`, `fontSettings.sdf === true`, `outlineWidth >= 2`, `outlineColor === [255,255,255,255]`, `getTextAnchor:'middle'`, `getAlignmentBaseline:'bottom'`, `pickable === false`.

- [ ] **AC-010.** Substantive: capitals and metros separate into two visual tiers (capitals bolder/darker/larger). Verification: vitest — capitals `getSize === 13`, `getColor === [40,40,40]`, `fontWeight 700`; metros `getSize === 11`, `getColor === [85,85,85]`, `fontWeight 400`; `sizeUnits:'pixels'` on both.

- [ ] **AC-011.** Substantive: metro labels do not flood the map at low zoom — they are gated below ~zoom 5 and collision-filtered. Verification: vitest for the gate predicate (a pure helper or the MapShell spread condition `showMetros && zoom >= 5`); manual — at zoom 4 with Metros on, no metro labels render; zooming to ≥5 reveals them; capitals win a collision over metros where they overlap. (`CollisionFilterExtension` on metros with capitals' higher `getCollisionPriority`; min-zoom-alone is the documented fallback if the extension proves heavy.)

### ZCTA overlay (`zctaSource.ts`) — operator-dependent, graceful degradation

- [ ] **AC-012.** Substantive: with `VITE_ZCTA_TILES_URL` unset, the ZIP toggle is native-`disabled` with an `aria-describedby` helper note "Configure a ZCTA tile source (VITE_ZCTA_TILES_URL) to enable.", and no source/request/console-error/layout-shift occurs. Verification: vitest — `zctaConfigured()` returns `false` when the env var is unset (mock `import.meta.env`); component test on the panel asserts the ZIP `<input>` has `disabled` (NOT `aria-disabled`), the helper note exists, and the input's `aria-describedby` points at it; `addZctaSource(map)` is a no-op when unconfigured (assert `map.addSource`/`map.addLayer` not called via a mock map). Manual — unset env: ZIP row dimmed, note present, console clean, no map request for tiles.

- [ ] **AC-013.** Substantive: with `VITE_ZCTA_TILES_URL` set, the ZCTA vector source + `zcta-fill`/`zcta-line` style layers are added once (initially hidden) and `setZctaVisible(map,on)` flips their `layout.visibility`. Verification: vitest — `zctaConfigured()` true when env set; `addZctaSource(mockMap)` calls `addSource` once and `addLayer` for `zcta-fill` then `zcta-line` with initial `visibility:'none'`; `setZctaVisible(mockMap,true)` calls `setLayoutProperty(...,'visibility','visible')` on both, `false` → `'none'`. Style assertions: `zcta-fill` `fill-color:'#6b7280'`/`fill-opacity ~0.04`; `zcta-line` `line-color:'#6b7280'` with zoom-interpolated opacity/width. **FLAG (operator-dependent):** full ZIP *tile rendering* verification requires an operator-provided `VITE_ZCTA_TILES_URL` — the build verifies the configured *wiring* + the unset/disabled path; live tile rendering is verified by the operator after provisioning (see Out of Scope / Deferrals).

- [ ] **AC-014.** Substantive: clicking a ZCTA boundary while the ZIP layer is visible shows a popup with the ZCTA5 zip code; when the layer is hidden/unconfigured the click is a silent no-op. Verification: vitest — the id-property resolver reads the pinned constant key (`ZCTA5CE20`/`GEOID20`, confirmed at tile-build time) with a fallback that probes for the first 5-digit property; manual (operator, post-provisioning) — ZIP on, click a boundary → `maplibregl.Popup` at the click point reading "ZIP {zcta5}"; ZIP off → no popup.

### Consolidated "Map layers" panel + lifted state

- [ ] **AC-015.** Substantive: the W4 `SaturationPanel` is refactored *in place* — heading renamed to "Map layers", the vertical select relabeled "Vertical", with two `<fieldset>` groups (Reference: capitals/metros/ZIP · Analysis: zones/saturation/prospecting), the filter checkbox, and a collapsible vertical color legend; the left CRUD `.site-panel` is untouched. Verification: vitest/RTL component test — render the panel; assert `<h2>` text "Map layers", a "Vertical" labeled `<select>`, two `<fieldset>`s with the named `<legend>`s and the listed checkboxes, the "Show only this vertical's sites" checkbox, and a `<details>` vertical legend; assert no second vertical `<select>` exists.

- [ ] **AC-016.** Substantive: the W4 a11y contract survives the refactor verbatim — `useId` on every control, the `aria-live="polite"` summary seeded-empty when no vertical, the conditional numeric saturation legend, native `disabled` (never `aria-disabled`) on every gated control. Verification: vitest/RTL — every control has an associated `<label htmlFor>`; the live region is empty with no vertical selected and the static "Select a vertical…" prompt is non-live; heatmap/prospecting/filter inputs carry `disabled` (not `aria-disabled`) when `selectedVertical===null`; the saturation legend shows only when `selectedVertical!==null && (showHeatmap||showProspecting)`.

- [ ] **AC-017.** Substantive: the vertical color legend lists one row per `VERTICAL_OPTIONS` (swatch + the human label) plus a "No vertical" neutral row, with the text label as the SR carrier (swatch `aria-hidden`); `VERTICAL_OPTIONS` is imported, never re-authored. Verification: vitest/RTL — legend has `VERTICAL_OPTIONS.length + 1` rows; each row's text equals `verticalLabel(token)` (and "No vertical" for the fallback); each swatch is `aria-hidden`; grep asserts `verticalStyle.ts`/the panel import `VERTICAL_OPTIONS` from `customers.ts` rather than redeclaring the token list.

- [ ] **AC-018.** Substantive: App lifts `showCapitals`/`showMetros`/`showZcta`/`showZones`/`filterToVertical` alongside the existing W4 toggles and passes them to both the panel and `MapShell`; defaults are capitals/metros/ZCTA/filter **off**, zones **on**. Verification: vitest/RTL on App — the five `useState` defaults match; the panel receives the setters; `MapShell` receives the layer props. (`showZcta` is wired through `setZctaVisible(map,showZcta)`, not the deck array — AC-013.)

### MapShell integration + z-order (the named ui-review legibility gate)

- [ ] **AC-019.** Substantive: the deck overlay array renders in the legibility-preserving z-order — wash → prospect → zones → pins → metro labels → capital labels (labels LAST/top; conditionally spread so toggled-off layers are omitted entirely). Verification: vitest — drive the spread builder with toggle combinations and assert the resulting layer-`id` order; with all reference toggles off the array equals the W4 array exactly (first-paint byte-identical invariant, `MapShell.tsx:129-149`). Manual (ui-review) — labels read above pins/wash; capitals win collisions over metros.

- [ ] **AC-020.** Substantive: the ZCTA fill/line render as MapLibre-native layers BENEATH the entire deck overlay (ZIP below pins), automatic by virtue of the overlay sitting above native layers. Verification: vitest — `addZctaSource` adds ordinary MapLibre layers (not deck layers); manual (ui-review, post-provisioning) — ZIP fill/line read *under* pins, zones, wash, and labels; the basemap reads through the ~0.04 fill.

- [ ] **AC-021.** Substantive: selecting a vertical from the single shared control drives BOTH the W4 saturation wash AND (when the filter is on) the pin filter — there is exactly one vertical control. Verification: vitest/RTL — changing the panel `<select>` calls the one `onSelectVertical`; with the filter on, the pin layer's `data` narrows to that vertical AND the saturation recompute keys on the same `selectedVertical`; grep asserts no second vertical-select element/state.

- [ ] **AC-022 (wire-to-consumer).** Substantive: each new unit is actually reached in the real path, not merely defined — `verticalStyle` is consumed by `sitePinsLayer.getFillColor`; `capitalsLayer`/`metrosLayer` are mounted in the `MapShell` overlay array; `zctaSource` helpers are called from `MapShell` (`addZctaSource` on load, `setZctaVisible` on `showZcta` change); the new panel controls are bound to lifted App state. Verification: `git grep -n 'VERTICAL_COLORS' src/components/sitePinsLayer.ts` (consumer call), `git grep -n 'capitalsLayer\|metrosLayer' src/components/MapShell.tsx`, `git grep -n 'addZctaSource\|setZctaVisible' src/components/MapShell.tsx`, and `git grep -n 'showCapitals\|showMetros\|showZcta\|filterToVertical' src/App.tsx` each show the invocation/binding site; an App/MapShell integration test asserts toggling a reference checkbox changes the rendered layer set (the call fires), not just that the factory exists.

### ui-review legibility gate (named gate — ACs)

- [ ] **AC-023.** Substantive: stacked-layer legibility passes ui-review — label halos keep capitals/metros readable over basemap, pins, and wash; pins stay crisp (opaque + 1px white stroke) above translucent zones/wash and never read as conflict/saturation/prospect colors; ZCTA fill/line stay subtle enough that everything above reads. Verification: `@ui-review` on the running app (capitals + metros + pins + zones + saturation all on, with a configured ZCTA source if available) returns no Critical legibility finding; manual checklist in the run folder records the four legibility checks (halo, pin crispness, palette-vs-reserved separation, ZIP subtlety).

- [ ] **AC-024.** Substantive: the code-reviewer gate passes — no re-authored `VERTICAL_OPTIONS`, no hardcoded tile token/URL (env-var only), no `MVTLayer` for ZCTA, no new floating panel, no Tailwind/CSS-vars (semantic classes + literal hex only). Verification: `@code-reviewer` on the wave diff returns no Critical/Major finding on these points; `git grep -nE 'VITE_ZCTA_TILES_URL' src/` shows the URL is only read from env, never a literal endpoint; `git grep -n 'MVTLayer' src/` returns nothing.

## Scope

### In Scope (Phase 1)

- **Per-vertical pin coloring** (always-on) via `VERTICAL_COLORS` + a panel color legend.
- **Opt-in single-vertical pin filter** driven by the one shared `selectedVertical`.
- **Capitals + metros label layers** from bundled static JSON (deck.gl `TextLayer`, halos, tiering, metro min-zoom + collision control).
- **ZIP/ZCTA overlay with full graceful degradation** — MapLibre native vector source gated on `VITE_ZCTA_TILES_URL`; configured *wiring* + click-to-zip popup + the unset→disabled-toggle path all in scope.
- **Consolidated "Map layers" panel** — in-place `SaturationPanel` refactor (heading, shared vertical select, filter checkbox, two fieldsets, collapsible vertical legend), W4 a11y contract preserved, left CRUD panel untouched.
- New lifted App state: `showCapitals`/`showMetros`/`showZcta`/`showZones`/`filterToVertical` (+ existing W4 state).
- No migration / no DB surface; first paint byte-identical when all reference toggles are off.

### Out of Scope (Future / operator-dependent)

- **Providing the actual ZCTA tileset URL and hosting the PMTiles archive** — CC cannot fabricate or host a tile source. The operator generates `zcta.pmtiles` from Census TIGER `tl_2020_us_zcta520` (tippecanoe), uploads to an HTTP-Range-capable public bucket (e.g. Supabase Storage), and sets `VITE_ZCTA_TILES_URL`. Until then the ZIP overlay ships dark via the in-scope disabled-toggle path (see Deferrals). **Interim:** the other three layers work with zero setup.
- **Per-vertical glyph icons** (`IconLayer` atlas) — color-by-vertical only this wave.
- **Responsive/mobile panel collapse** — desktop tool; the right panel scrolls within `70vh`.
- **A decennial refresh of `metros.json`** — a JSON edit, not a code change.
- **Keyboard equivalent for click-to-zip** — accepted `role="application"` canvas limitation (the popup is an exploratory enhancement, not a required-information carrier; consistent with W3/W4).

### Files in scope

- `src/lib/verticalStyle.ts` — *create* (`VERTICAL_COLORS`, `VERTICAL_NEUTRAL`)
- `src/lib/verticalStyle.test.ts` — *create* (AC-001/002/003)
- `src/data/capitals.json` — *create*
- `src/data/metros.json` — *create* (+ provenance note: `src/data/metros.source.md` or a `_meta` provenance row — AC-008)
- `src/components/referenceLabelsLayer.ts` — *create* (`capitalsLayer`/`metrosLayer`)
- `src/components/referenceLabelsLayer.test.ts` — *create* (AC-009/010)
- `src/components/zctaSource.ts` — *create* (`zctaConfigured`/`addZctaSource`/`setZctaVisible` + click-to-zip helper)
- `src/components/zctaSource.test.ts` — *create* (AC-012/013/014)
- `src/components/sitePinsLayer.ts` — *modify* (signature → `sitePinsLayer(sites, { selectedVertical, filterToVertical })`; palette `getFillColor` + opt filter)
- `src/components/sitePinsLayer.test.ts` — *create* (AC-004/005/006)
- `src/components/SaturationPanel.tsx` — *modify* (in-place refactor → "Map layers": heading, "Vertical" relabel, filter checkbox, two fieldsets, vertical legend; keep W4 a11y)
- `src/components/SaturationPanel.test.tsx` — *create* (AC-015/016/017)
- `src/components/MapShell.tsx` — *modify* (accept reference props; mount ZCTA native source; extend deck array + z-order; metro min-zoom gate off lifted `zoom`)
- `src/App.tsx` — *modify* (lift `showCapitals`/`showMetros`/`showZcta`/`showZones`/`filterToVertical`; pass to panel + MapShell)
- `src/index.css` — *modify* (add `.layers-fieldset`, `.vertical-legend`, `.zcta-popup`; reuse existing classes)
- `.env.example` — *modify* (document `VITE_ZCTA_TILES_URL` with the disabled-when-unset note)
- `docs/zcta-tiles-setup.md` — *create* (operator note: tippecanoe build + upload + env-var step — the operator-dependency runbook)

## Technical Notes

### Existing Patterns to Reuse

- **Per-file deck.gl layer factory** — `sitePinsLayer.ts`, `siteZonesLayer.ts`, `saturationLayer.ts`; mirror for `referenceLabelsLayer.ts`. `TextLayer` imports from the `deck.gl` umbrella as `ScatterplotLayer`/`H3HexagonLayer` already do.
- **Reactive conditional-spread overlay + load-bearing z-order** — `MapShell.tsx:129-149`; extend, do not rewrite. The byte-identical-first-paint invariant is the constraint.
- **Lifted-state pattern** — `App.tsx:84-90` (W4 toggles); add the five new flags identically.
- **`useId` labels + native `disabled` + `aria-live` seeded-empty + numeric legend** — `SaturationPanel.tsx`; preserve verbatim through the refactor.
- **`updateTriggers` stable-key idiom** — `siteZonesLayer`'s `conflictKey` (only if a `getFillColor` trigger is wanted; constant key, not per-frame).
- **`VERTICAL_OPTIONS` / `verticalLabel`** — `customers.ts:70-88`; import, never re-author. `VERTICAL_COLORS` keys on the same tokens.
- **Keyless tile source precedent** — `MapShell.tsx:76` (OpenFreeMap `liberty`, no key); ZCTA env-var token discipline follows rules-security.
- **Layer-config tests without a GL context** — `saturationLayer.test.ts` (deck.gl layers construct in the node env; props inspectable).

### New Components Needed

- `verticalStyle.ts` (palette), `referenceLabelsLayer.ts` (two TextLayer factories), `zctaSource.ts` (MapLibre-native source helpers + click-to-zip), the two static JSON data files, and the three new CSS classes. The `SaturationPanel`/`MapShell`/`App`/`sitePinsLayer` edits are extensions of existing units.

### Data Lifecycle

| Entity | Source | Created By | Management Interface | Status |
|--------|--------|------------|---------------------|--------|
| Site pins (`site_geo`) | existing PostGIS table | end user (W2 CRUD) | existing `CustomerForm`/`CustomerList`/`CustomerImport` | exists |
| `site_geo.vertical` | existing column | end user (W3) | existing customer CRUD vertical select | exists |
| Capitals | new bundled `src/data/capitals.json` | repo author (this wave) | static — edit the JSON (reference geography, no UI) | in-scope |
| Metros | new bundled `src/data/metros.json` | repo author (this wave) | static — edit the JSON; decennial refresh is a JSON edit | in-scope |
| ZCTA boundaries | external/self-hosted vector tiles via `VITE_ZCTA_TILES_URL` | **operator** (provision tileset) | `VITE_ZCTA_TILES_URL` env var; until set, ZIP toggle is disabled with helper note | **deferred (operator)** |

**Interim data strategy for ZCTA:** the only read with no in-repo source is the ZCTA tileset. It is designed to degrade gracefully — `zctaConfigured()` false → disabled toggle + helper note, no error, no layout shift (AC-012). The operator runbook (`docs/zcta-tiles-setup.md`) documents generating + hosting the PMTiles and setting the env var. The other three layers require zero operator setup. This is the carry-forward deferral (see Deferrals).

### Database Changes

- **None.** No new table, view, column, RPC, RLS policy, or index. Capitals/metros are bundled static JSON; ZCTA is consumed by the basemap library; `vertical` is already on `customer`/`site_geo` (W3). The only tenant read added is an in-memory filter over the already-RLS-scoped `site_geo`. `db-migration-reviewer` gate NOT required (ADR-005 D5).

### API / Edge Functions

- **None.** ZCTA tiles are fetched by MapLibre directly from `VITE_ZCTA_TILES_URL` (PMTiles via the `pmtiles` protocol or a third-party tileset). No backend endpoint.

### Security Considerations

- **No hardcoded tile token/URL** (rules-security) — the ZCTA source is read from `VITE_ZCTA_TILES_URL` only; any token rides in the configured URL via env, never committed (`.env.example` documents it; `.env` stays gitignored).
- **No new RLS surface** — the vertical filter is an in-memory pass over already-RLS-scoped `site_geo`; no new auth path.
- **No console error / broken request** on the unconfigured ZCTA path (graceful degrade is also a no-leak posture — no failed tile request reveals config state).

### Accessibility Requirements (WCAG 2.2 AA)

- Every new control native + `useId`-labeled; the two toggle groups are `<fieldset>`/`<legend>`; the vertical legend `<details>`/`<summary>` is keyboard-operable.
- Gated controls (ZIP when unconfigured; filter/heatmap/prospecting when no vertical) use native `disabled`, never `aria-disabled` (W4 contract).
- The ZIP disabled note is tied via `aria-describedby` — no unexplained disabled state.
- Vertical never signalled by color alone — the legend (real text per row, swatch `aria-hidden`) + the opt-in filter are the authoritative carriers; pin color is orientation/reinforcement.
- Map labels carry a white sdf halo (legibility, not a contrast shortcut); every `VERTICAL_COLORS` fill clears 3:1 graphical on white (ui-spec §4 table, min ~4.5:1).
- The kept `aria-live="polite"` summary stays seeded-empty when no vertical (no first-paint auto-announce); nothing here uses `role="alert"`.
- Click-to-zip has no keyboard equivalent — accepted `role="application"` canvas limitation; the popup is exploratory, not a required-information carrier.

## Open questions / assumptions

- **ZCTA id property name** (`ZCTA5CE20` vs `GEOID20`) varies by built tileset. *Assumption:* pin the key as a constant in `zctaSource.ts` confirmed at the operator's tile-build time, with a fallback that probes for the first 5-digit property. Proceeding with the pinned-constant-plus-fallback design (ADR-005 Risk).
- **Metro collision extension weight.** *Assumption:* apply both `CollisionFilterExtension` (capitals higher priority) and the min-zoom gate; if the extension proves heavy in practice, min-zoom-alone is the documented acceptable fallback (AC-011).
- **`metros.json` provenance carrier.** *Assumption:* since JSON forbids comments, record the 2020 CBSA vintage in a sibling `src/data/metros.source.md` (or a leading `_meta` row); AC-008 accepts either.
- **`showZones` toggle.** *Assumption (per ui-spec Deviation Log):* add a "Site zones" toggle (default on) to the Analysis fieldset to honor the kickoff's "Analysis: zones, saturation, prospecting" — additive, conditionally-spread `siteZonesLayer`, no W3/W4 logic change. Encoded in AC-015/018.

## ADR alignment

| ADR | Cited in | Operationalized by | Divergence | Rationale |
|---|---|---|---|---|
| ADR-005 D1 (ZCTA = MapLibre native source, env-var, graceful degrade) | prompt / adr / cto | AC-012, AC-013, AC-014, AC-020 | none | aligned |
| ADR-005 D2 (capitals+metros static JSON → TextLayer) | adr | AC-007..AC-011 | none | aligned |
| ADR-005 D3 (one shared `selectedVertical`; always-on color; opt-in filter) | adr / cto | AC-001..006, AC-021 | none | aligned |
| ADR-005 D4 (one consolidated panel; no W4 rewrite) | adr / cto | AC-015..018, AC-019 | none | aligned |
| ADR-005 D5 (no migration) | adr | "Database Changes: None" | none | aligned |
| ADR-001..004 (foundation/customers/exclusivity/saturation) | adr | reuse-only (read `site_geo`, extend MapShell/panel) | none | read-only, additive |

## Dependencies

- **Extends W3/W4** (the map + `SaturationPanel` + lifted-state surface) but is **independent of W2–W4 tenant data** — the only tenant read is an in-memory filter over already-loaded `site_geo`. W1–W4 are merged to main.
- **Operator dependency (carry-forward deferral):** the live ZIP overlay requires the operator to provision + host a ZCTA tileset and set `VITE_ZCTA_TILES_URL`. Tracked as a separate operator-setup atom (the `docs/zcta-tiles-setup.md` runbook), not a code blocker — the wave ships its other three layers and the disabled-toggle path with zero setup.
- **Cross-wave seam:** read-only, additive, no W2–W4 source change → standalone single-wave `/orchestrated` build; no `crossWavePrior`, architect-final not required (ADR-005 Notes).

## Deferrals (carry-forward)

- **DEFER reference-overlays → operator-setup:** generate + host the ZCTA PMTiles (Census TIGER ZCTA5 → tippecanoe → HTTP-Range public bucket) OR supply a third-party tileset URL, then set `VITE_ZCTA_TILES_URL`. Until done the ZIP overlay is the in-scope disabled-toggle graceful state. Runbook: `docs/zcta-tiles-setup.md`. [found_by=pm-spec, at=2026-06-28]
- **DEFER reference-overlays → standalone:** per-vertical glyph icons (IconLayer atlas) and responsive/mobile panel collapse — explicitly out of scope this wave. [found_by=pm-spec, at=2026-06-28]
