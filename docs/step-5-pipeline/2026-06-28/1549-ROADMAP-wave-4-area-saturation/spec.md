# Feature Spec: Area-Saturation Heatmap (Wave 4)

**Status:** Draft
**Author:** AI-assisted (pm-spec agent — integrator, final funnel step)
**Date:** 2026-06-28
**Slug:** area-saturation
**Ticket key:** HGW-4
**ADR:** ADR-004 (`docs/step-5-pipeline/2026-06-28/1549-ROADMAP-wave-4-area-saturation/adr.md`)
**UI Spec:** `ui-spec-addendum.md` (same run folder)
**CTO verdict:** SIMPLIFY → GO with trimmed scope (`findings/cto-advisor.md`)

## Summary

Wave 4 is the hex payoff: a per-vertical **saturation heatmap** answering "how locked-up is this
territory" plus a **prospecting view** ("open area near here"). Coverage is computed **client-side with
`h3-js`** over the tenant `site_geo` set already resident in `App.sites` — viewport-tessellated on
debounced `moveend`, zoom-adaptive H3 resolution, hard cell-count cap. The metric is **overlap-weighted**
(per-cell count of active same-vertical zones covering the cell centroid; 0 = open), rendered as a deck.gl
`H3HexagonLayer` mounted UNDER the W3 zones+pins. **No backend, no migration, no RPC, no RLS surface** —
the feature inherits W3's tenant isolation by reading the already-scoped in-memory set.

## User Stories

- As a sales/territory operator, I want a saturation heatmap of a chosen vertical so I can see at a glance
  how locked-up a territory is.
- As an operator, I want denser coloring where multiple same-vertical zones overlap so I can distinguish
  lightly- from heavily-covered areas.
- As a prospector, I want open (zero-coverage) cells near my current view highlighted so I can find
  available territory, and optionally jump to the nearest open area.
- As an operator, I want to choose which vertical's saturation I'm viewing (saturation is only meaningful
  within a vertical) with no heatmap shown until I choose.
- As an operator, I want to hide the wash to inspect the underlying W3 zones/pins without losing my
  selected vertical.
- As a screen-reader user, I want a textual summary and a numeric legend so I get the same "how locked-up /
  how much open" answer the canvas conveys.

## Acceptance Criteria

ACs are biased toward the vitest harness (pure compute) where possible; canvas/render and a11y ACs carry a
precise manual/inspection procedure. `effectiveRadiusMi`, the coverage compute, `saturationLayer`, and
`prospectLayer` each carry a wire-to-consumer atom (invocation-site proof, not mere existence).

### Shared effective-radius helper (drift kill)

- [ ] **AC-001.** Substantive: a single shared helper `effectiveRadiusMi(site)` returns
  `is_zone_on ? (exclusivity_radius_mi ?? 0) : 0` (miles) — the exact W3 effective-zone rule — for the
  off/null/zero/positive cases. Verification: vitest unit asserts `effectiveRadiusMi` returns `0` for
  `is_zone_on:false`, `0` for `exclusivity_radius_mi:null` (zone on), `0` for `0`, and the radius for a
  positive on-zone. (ADR D2; risk "client/server effective-radius drift".)
- [ ] **AC-002.** Substantive: `siteZonesLayer` is refactored to CONSUME `effectiveRadiusMi` for its
  effective-zone filter (it no longer inlines `is_zone_on && exclusivity_radius_mi != null && > 0`), so the
  heatmap and the W3 circles can never drift. Verification (wire-to-consumer): `git grep -n
  'effectiveRadiusMi' src/components/siteZonesLayer.ts` shows the call site inside the `data` filter; the
  existing W3 zone tests still pass (`npm test`). Exclusions: n/a (single-repo).
- [ ] **AC-003.** Substantive: a parity test pins `effectiveRadiusMi` to the W3 conflict-RPC predicate
  semantics (the `is_zone_on` fold + miles→meters constant `1609.344` used by `siteZonesLayer.ts:52`) so a
  future edit to one side breaks the test. Verification: vitest asserts, for a representative set, that
  `effectiveRadiusMi(s) > 0` iff the site would draw a W3 circle, and that `effectiveRadiusMi(s) * 1609.344`
  equals the meters radius `siteZonesLayer` renders.

### Coverage compute (overlap-weighted) — vitest-checkable

- [ ] **AC-004.** Substantive: a cell whose centroid lies within N active same-vertical effective zones
  gets `coverage === N` (overlap-weighted count, NOT a boolean). Verification: vitest — place 3 same-vertical
  on-zones so a known cell centroid is inside exactly 2 → assert that cell's `coverage === 2`; inside all 3
  → `3`. (ADR D2 overlap-weighted extension; cto SIMPLIFY pick; ui-spec §4.)
- [ ] **AC-005.** Substantive: a cell whose centroid is outside every zone has `coverage === 0` (open).
  Verification: vitest — a cell centroid > eff from all zones → `coverage === 0`.
- [ ] **AC-006.** Substantive: zones of a vertical OTHER than the selected vertical never contribute to
  coverage. Verification: vitest — a cell centroid inside a `grocery` zone, `selectedVertical === 'gas'` →
  `coverage === 0`; same cell with `selectedVertical === 'grocery'` → `coverage === 1`.
- [ ] **AC-007.** Substantive: a zone with `is_zone_on === false` OR null/zero `exclusivity_radius_mi`
  never contributes (it has no effective radius). Verification: vitest — a cell centroid geographically
  inside such a zone → `coverage === 0` (compute goes through `effectiveRadiusMi`).
- [ ] **AC-008.** Substantive: coverage is owner-independent — `self_conflict` and `customer_id` do NOT
  participate; every active same-vertical zone counts regardless of owner. Verification: vitest — identical
  zone set with `self_conflict` true vs false (and same vs different `customer_id`) → identical `coverage`
  for every cell. (ADR D2; cto fork: self_conflict IGNORE.)
- [ ] **AC-009.** Substantive: per-cell coverage uses centroid-in-circle — `haversineMi(cellToLatLng(cell),
  {lat,lng}) <= effectiveRadiusMi(site)` — as the membership test. Verification: vitest — a cell centroid
  0.4 mi from a 0.5 mi on-zone ⇒ counted; 0.6 mi ⇒ not counted (boundary cases). (ADR D2 formula.)

### Perf gate (the named single concentrated risk) — vitest + measurement

- [ ] **AC-010.** Substantive: H3 resolution is zoom-adaptive per the ADR D4 table (zoom <5→res4,
  5–7→res6, 8–10→res7, >10→res8), clamped at the bounds. Verification: vitest — a pure
  `resolutionForZoom(zoom)` returns the table value for representative zooms incl. the bracket edges and
  out-of-range (zoom 0 → 4, zoom 22 → 8).
- [ ] **AC-011.** Substantive: a hard per-recompute cell-count cap bounds the tessellation — above the cap
  at the current resolution the compute raises resolution / skips rather than tessellating an unbounded
  bbox, and surfaces "Zoom in to compute saturation" (never silently renders nothing). Verification: vitest
  — a CONUS-scale padded bbox at the low-zoom resolution yields a candidate cell count that the cap path
  rejects (returns the capped/empty result + the cap flag), while a metro bbox passes. (ADR perf gate; cto
  "cell-count explosion at low zoom".)
- [ ] **AC-012.** Substantive: the cell set recomputes on debounced `moveend` (~200 ms), on
  `selectedVertical` change, and on data reload (`version`) — NEVER per render/per frame. Verification:
  inspection — the recompute is wired to a `moveend` handler debounced ~200 ms (no recompute in a render
  body / per-frame callback); `git grep -n 'moveend' src/` shows the single debounced binding. Mirrors W3
  "recompute on data change, never per frame" (`App.tsx:21-24`).
- [ ] **AC-013.** Substantive: zones are pre-filtered to the padded viewport bbox + selected vertical
  BEFORE the per-cell inner loop (so cost is `O(cells × zonesInViewport)`, not `× allZones`). Verification:
  vitest — given zones inside and far outside the bbox, the inner loop only considers the in-bbox subset
  (assert via a counting spy or by asserting a far-outside zone never affects coverage even when its eff
  radius nominally could). (ADR D1 step 3.)
- [ ] **AC-014.** Substantive: the `saturationLayer`/`prospectLayer` `updateTriggers` are keyed on
  `[selectedVertical, dataVersion, resolution]` so deck.gl re-evaluates accessors only on real change.
  Verification: inspection — `git grep -n 'updateTriggers' src/components/saturationLayer.ts` shows the
  three-key trigger; mirrors `siteZonesLayer.ts:62-66`. (ADR D1/perf gate; ui-spec §5.)

### Prospecting

- [ ] **AC-015.** Substantive: prospecting surfaces the `coverage === 0` cells of the current viewport,
  ranked by `haversineMi(cellToLatLng(cell), viewportCenter)` ascending, capped to top-N. Verification:
  vitest — a viewport with known open cells at varying distances returns them in nearest-first order, length
  ≤ N. (ADR D5; ui-spec §7.)
- [ ] **AC-016.** Substantive (optional, D5): a "Jump to nearest open area" button pans the map to the
  nearest `coverage === 0` cell centroid and announces it via the `aria-live` summary; disabled when there
  are no open cells in view or no vertical selected. Verification: manual — choose a vertical with open
  cells in view, click → map eases to the nearest open cell, summary announces "Centered on nearest open
  area."; with no open cells the button is `disabled`. (ui-spec §7.)

### Render, layer wiring, and z-order

- [ ] **AC-017.** Substantive: `saturationLayer(cells)` returns a deck.gl `H3HexagonLayer` (`getHexagon:
  d=>d.h3`, `extruded:false`, `filled:true`, `stroked:false`, `pickable:false`) whose `getFillColor` keys
  on `d.coverage` via the discrete Blues ramp — `1 → [198,219,239,150]`, `2 → [107,174,214,170]`,
  `>=3 → [21,88,176,190]` — and whose `data` is only `coverage >= 1` cells. Verification: vitest — the
  fill accessor returns the exact RGBA for coverage 1/2/3/4 (4 clamps to the 3+ bucket); the builder filters
  out `coverage === 0`. (ui-spec §4/§5; ADR D4.)
- [ ] **AC-018.** Substantive (wire-to-consumer): `saturationLayer` is actually mounted by `MapShell` —
  not merely defined — FIRST in the overlay array so the wash sits under everything:
  `[saturationLayer(cells), prospectLayer(openCells), siteZonesLayer(sites, conflictIds),
  sitePinsLayer(sites)]`. Verification: `git grep -n 'saturationLayer' src/components/MapShell.tsx` shows
  the call site inside `overlay.setProps({layers:[…]})`, positioned before `siteZonesLayer`; manual — the
  wash renders beneath the W3 zone rings and pins. (ui-spec §5 z-order; extends `MapShell.tsx:64-68`.)
- [ ] **AC-019.** Substantive (wire-to-consumer): `prospectLayer(openCells)` returns a green-outline
  `H3HexagonLayer` (`getFillColor:[19,115,51,35]`, `stroked:true`, `getLineColor:[19,115,51,230]`,
  `getLineWidth:2`, `lineWidthUnits:'pixels'`) and is mounted by `MapShell` above the wash, below zones.
  Verification: `git grep -n 'prospectLayer' src/components/MapShell.tsx` shows the call site in the layer
  array between `saturationLayer` and `siteZonesLayer`; vitest asserts the line/fill RGBA. (ui-spec §7.)
- [ ] **AC-020.** Substantive: the `saturationLayer` is OMITTED from the array entirely (not rendered
  empty) when `selectedVertical === null` OR the heatmap toggle is off; `prospectLayer` is omitted when the
  prospecting toggle is off OR `selectedVertical === null` — first paint stays byte-identical to W3.
  Verification: inspection — the array spreads conditionally (`...(showHeatmap && selectedVertical ?
  [saturationLayer(cells)] : [])`); manual — with no vertical chosen the map matches W3 exactly. (ui-spec
  §5/§7; anti-pattern §9.)

### Saturation control panel + a11y

- [ ] **AC-021.** Substantive: a new floating `.saturation-panel` (top-right) holds the vertical selector,
  heatmap toggle, prospecting toggle, legend, and textual summary; the left `.site-panel` CRUD surface is
  untouched. Verification: manual — the panel renders at `top:3rem;right:1rem`; `git diff` shows no change
  to `CustomerList`/`CustomerForm`/`.site-panel`. New state `selectedVertical`/`showHeatmap`/
  `showProspecting` lifted alongside `conflictIds` (`App.tsx:53-56`). (ui-spec §2/§6.)
- [ ] **AC-022.** Substantive: the vertical control is a native `<select>` over `VERTICAL_OPTIONS`
  (imported, NOT re-authored) with a default `"Select vertical…"` (`value=""` → `selectedVertical=null`, no
  heatmap). Verification: `git grep -n 'VERTICAL_OPTIONS' src/components/SaturationPanel.tsx` shows the
  import-and-map; manual — first option is the empty prompt and no heatmap shows until a real vertical is
  chosen. (ui-spec §6; reuse `customers.ts:70-80`.)
- [ ] **AC-023.** Substantive: the heatmap toggle (`Show saturation heatmap`) defaults checked and is
  `disabled` while `selectedVertical===null`; the prospecting toggle (`Highlight open areas`) defaults
  unchecked and is `disabled` while `selectedVertical===null`; both are native `<input type="checkbox">`
  with `useId` labels. Verification: manual — with no vertical both are dimmed/non-tabbable (native
  `disabled`, not `aria-disabled`); after choosing a vertical both enable. (ui-spec §6/§8.)
- [ ] **AC-024.** Substantive: a legend renders the ramp as swatch + REAL numeric text rows
  (`Open (0 zones)` / `1 zone` / `2 zones` / `3+ zones`) — never color-alone — each swatch `aria-hidden`
  with a `#555` hairline border. Verification: manual + DOM inspection — legend `<li>` text carries the
  count; swatches are `aria-hidden="true"`. (ui-spec §4/§8; never-color-alone.)
- [ ] **AC-025.** Substantive: a `.helper-text aria-live="polite"` textual summary updates on every
  recompute with "Saturation for {vertical label}: {coveredCount} covered cells, {openCount} open cells near
  center." and is the SR carrier equivalent of the canvas. Verification: manual with a screen reader / DOM —
  the live region updates on vertical change and on `moveend`. (ui-spec §8; reuse `verticalLabel`.)
- [ ] **AC-026.** Substantive: the panel surfaces computing/cap/empty states in the same `aria-live` line —
  "Computing saturation…" during a debounced recompute; "Zoom in to compute saturation" when the cell cap
  trips; "Select a vertical to view saturation." when none chosen; "No {vertical} zones in this area — all
  open." when a vertical is chosen but no zones are in view. Verification: manual — drive each state; the
  notice never silently renders nothing. (ui-spec §8.)
- [ ] **AC-027.** Substantive: all new controls are native and keyboard-accessible — Tab focus, native
  activation, inheriting the global `:focus-visible` (`2px #1a73e8`); no `<div onClick>`, no
  `aria-disabled` divs, no focus override. Verification: manual keyboard pass — Tab reaches select + both
  toggles + the jump button; each shows the global focus ring. (ui-spec §8; W2 AC-020 precedent.)

### Dependency, styling, scope guards

- [ ] **AC-028.** Substantive: `h3-js` is added as a direct `dependencies` entry in `package.json` (used
  for `polygonToCells`/`cellToLatLng`); `H3HexagonLayer` is imported from the `deck.gl` umbrella (as
  `ScatterplotLayer` already is), NOT relied on transitively. Verification: `git grep -n '"h3-js"'
  package.json` shows it under dependencies; `git grep -n "from 'deck.gl'" src/components/saturationLayer.ts`
  shows the umbrella import; `npm ci && npm run build` succeeds. (ADR D4; ui-spec §1.)
- [ ] **AC-029.** Substantive: new visual rules are added as semantic CSS classes in `src/index.css`
  (`.saturation-panel`, `.sat-legend`, `.sat-legend__swatch`) reusing existing `.field`/`.field-checkbox`/
  `.helper-text`/`.btn-secondary`; only the two sanctioned new hex stops `#c6dbef`/`#6baed6` are
  introduced (everything else reuses `#1558b0`/`#137333`/`#555`/`#ddd`); no Tailwind, no CSS variables, no
  arbitrary inline TSX hex (the dynamic legend-swatch background is the one sanctioned data-driven inline
  style). Verification: `git grep -nE '#c6dbef|#6baed6' src/` returns only the ramp/legend definitions; no
  `bg-`/`text-` utility classes or `var(--` introduced. (ui-spec §4/§9.)
- [ ] **AC-030.** Substantive: NO database surface is added — no migration `0005`, no RPC, no view change,
  no RLS policy; the feature reads only the already-loaded `site_geo` rows in `App.sites`. Verification:
  `git status` / `git diff --stat` show no new file under `supabase/migrations/` and no `.sql` change;
  the compute path makes no `supabase.rpc`/`supabase.from` call. (ADR D6; cto NO backend.)

## Scope

### In Scope (Phase 1 — SIMPLIFY cut)

- Client-side `h3-js` viewport tessellation on debounced `moveend`; zoom-adaptive resolution + hard
  cell-count cap.
- Overlap-weighted per-cell coverage (count of active same-vertical effective zones covering the centroid;
  0 = open), computed over `App.sites`.
- Shared `effectiveRadiusMi(site)` helper consumed by BOTH the saturation compute and (refactored)
  `siteZonesLayer`, with a parity test.
- Per-vertical heatmap via a vertical `<select>` (reuse `VERTICAL_OPTIONS`); default none → no heatmap.
- `saturationLayer` (deck.gl `H3HexagonLayer`) mounted UNDER zones+pins; discrete Blues ramp + legend +
  `aria-live` textual summary.
- Prospecting: `prospectLayer` green-outline highlight of zero-coverage viewport cells near center;
  optional "Jump to nearest open area".
- New floating `.saturation-panel` (top-right) with selector + heatmap/prospecting toggles + legend +
  summary; left CRUD panel untouched. New direct dep `h3-js`.

### Out of Scope (Future)

- **Metro / ZIP aggregation** → Wave 5 (reference-overlays owns the ZIP overlay). Carry-forward deferral.
- **Server-side compute** (PostGIS `h3-pg` / `ST_HexagonGrid` RPC) → deferred to the >10k-site scale
  tripwire; the in-memory client compute is the first cut (ADR D6, Alternatives). Carry-forward deferral.
- **Prospecting persistence** (saving/sharing open-area picks) → not this wave.
- **Responsive/mobile collapse** of the two floating panels → desktop tool; flagged for a future pass
  (ui-spec Deviation Log).

### Files in scope

- `src/lib/coverage.ts` — *create* (the `effectiveRadiusMi` helper, `resolutionForZoom`, the
  viewport-coverage compute `{ h3, coverage }[]`, the prospecting rank, and the cell-cap guard — the pure,
  vitest-covered core)
- `src/lib/coverage.test.ts` — *create* (AC-001/003/004–011/013/015 + ramp/clamp tests)
- `src/components/saturationLayer.ts` — *create* (`saturationLayer` + `prospectLayer` deck.gl
  `H3HexagonLayer` builders, mirroring `siteZonesLayer.ts`)
- `src/components/SaturationPanel.tsx` — *create* (top-right panel: selector + toggles + legend + summary +
  jump button)
- `src/components/siteZonesLayer.ts` — *modify* (refactor the effective-zone filter to consume
  `effectiveRadiusMi`)
- `src/components/MapShell.tsx` — *modify* (extend props + the reactive overlay array with
  `saturationLayer`/`prospectLayer`; add the debounced `moveend` viewport seam)
- `src/App.tsx` — *modify* (lift `selectedVertical`/`showHeatmap`/`showProspecting` + viewport state;
  render `SaturationPanel`; pass cells/flags to `MapShell`)
- `src/index.css` — *modify* (`.saturation-panel`, `.sat-legend`, `.sat-legend__swatch`; two new hex stops)
- `package.json` — *modify* (add `h3-js` to dependencies)

*(Whether the viewport-driven compute lives in `App` or `MapShell` is the implementer's call per ADR D1/D3;
both are listed. No new migration/RPC file is authorized — AC-030.)*

## Technical Notes

### Existing Patterns to Reuse

- `src/components/siteZonesLayer.ts` — the deck.gl layer factory shape to mirror for `saturationLayer.ts`
  (RGBA-literal coloring keyed on a per-datum value, the data filter, `updateTriggers` with a stable key).
  Its inline effective-zone filter (`:34-41`) becomes the `effectiveRadiusMi` consumer (AC-002).
- `src/components/MapShell.tsx` — the reactive `overlay.setProps({layers:[…]})` seam (`:64-68`) to extend
  with the new layer array order; the `role="application"` canvas a11y posture.
- `src/App.tsx` — the lifted-state + "recompute on data change, never per frame" pattern
  (`conflictIds`/`conflictsBySite`, `:44-99`); add `selectedVertical`/`showHeatmap`/`showProspecting` +
  the viewport-driven cell compute.
- `src/lib/customers.ts` — `VERTICAL_OPTIONS` (`:70-80`) + `verticalLabel()` (import; do NOT re-author).
- `src/index.css` — `.site-panel` (clone for `.saturation-panel`), `.field`/`.field-checkbox`/
  `.helper-text`/`.btn-secondary`, the word/number-not-color-alone idiom.

### New Components Needed

- `src/lib/coverage.ts` — pure compute core: `effectiveRadiusMi`, `resolutionForZoom`, the viewport
  tessellation + overlap-weighted coverage, the prospecting rank, the cell-cap guard. This is the
  vitest-covered heart of the wave.
- `src/components/saturationLayer.ts` — `saturationLayer` + `prospectLayer` (`H3HexagonLayer` builders).
- `src/components/SaturationPanel.tsx` — the top-right control panel.

### Data Lifecycle

| Entity | Source | Created By | Management Interface | Status |
|--------|--------|------------|---------------------|--------|
| `site_geo` rows (lat/lng/exclusivity_radius_mi/is_zone_on/vertical) | existing `site_geo` view (W2/W3), already loaded into `App.sites` | end user via W2 CustomerForm/Import + W3 zone/vertical controls | EXISTS — W2/W3 CRUD surfaces (`CustomerForm`/`CustomerList`/`CustomerImport`) | exists |
| `VERTICAL_OPTIONS` (selector source) | `src/lib/customers.ts:70-80` constant | code (controlled vocabulary) | EXISTS — imported constant | exists |
| Coverage cells `{ h3, coverage }[]` | COMPUTED client-side from `App.sites` + viewport (`coverage.ts`) | system (pure function, no persistence) | n/a — derived, ephemeral, recomputed on moveend/vertical/reload | computed |
| Prospecting open cells | COMPUTED subset (`coverage === 0`) ranked by distance | system | n/a — derived from the same cell set | computed |

Every read entity has a concrete write path: `site_geo` is written by the shipped W2/W3 CRUD surfaces;
`VERTICAL_OPTIONS` is a code constant; coverage/prospect cells are derived read-only and never persisted
(no write path needed — AC-030).

### Database Changes

- **NONE** (ADR D6 / AC-030). No migration, no view change, no RPC, no index, no RLS policy. The feature
  reads only the already-loaded, already-RLS-scoped `site_geo` set in memory.

### API / Edge Functions

- **NONE.** No new endpoint or Edge Function. (The geocoding Edge Function from W2 is untouched.)

### Security Considerations

- No new data-access surface → no new RLS to audit; the feature inherits W3's tenant isolation by reading
  the already-scoped in-memory `App.sites` set (ADR Benefits). The coverage loop ignores `customer_id`/
  `self_conflict` — it is a read-only territory aggregate, not a write-gating rule (ADR D2).
- No untrusted input crosses a trust boundary (viewport bounds + the controlled vertical token drive a pure
  client computation). No secrets, no PII logging (project security rules).
- `db-migration-reviewer` gate is NOT required (no migration — ADR D6); named gates are
  performance-reviewer + code-reviewer (skeleton).

### Accessibility Requirements (WCAG 2.2 AA)

- The canvas heatmap is not SR-accessible by nature; the accessible path is the panel chrome — a numeric
  **legend** (never color-alone) + an `aria-live="polite"` **textual summary** carrying coveredCount /
  openCount (AC-024/AC-025), mirroring W3's chrome-scoped a11y (A11Y-011).
- All controls native with `useId` labels; native `disabled` for gated toggles (not `aria-disabled` divs);
  global `:focus-visible` inherited, never overridden (AC-027).
- Discrete ordered Blues ramp + `#555` swatch hairline + numeric labels satisfy the 3:1 graphical bar and
  the never-color-alone rule; prospecting green `#137333` (not red — red reserved for W3 conflict) clears
  3:1 graphical (ui-spec §4/§8).

## Open questions / assumptions

- **Metric = overlap-weighted (resolved).** ADR-004 D2 wrote boolean-first; the binding decided-context +
  cto SIMPLIFY pick is **overlap-weighted** (per-cell zone count; 0 = open). Encoded as overlap-weighted
  throughout (a same-loop extension of D2's own "drop-in" note). Assumption: the `>=3` clamp bucket is the
  density ceiling for the legend (ui-spec §4) — revisit only if operators need finer high-end buckets.
- **Top-N for prospecting** — exact N (ui-spec "top-N nearest") is left to the implementer; assumption: a
  small constant (~20–50) keeps the green layer legible. Tunable; not load-bearing.
- **Compute home (App vs MapShell)** — ADR D1/D3 leave it open; assumption: the viewport-driven compute can
  live in either, lifted alongside `conflictIds`. Both files are in scope.
- **Cell-cap exact value** — ADR names "a hard per-recompute cell cap"; assumption: the implementer sets a
  concrete bound (e.g. a few thousand cells) validated by the performance-reviewer worst-case (CONUS-zoom,
  max sites) measurement. The AC tests the cap BEHAVIOR (reject CONUS bbox, pass metro), not a magic number.

## ADR alignment

| ADR | Cited in | Operationalized by | Divergence (if any) | Rationale |
|---|---|---|---|---|
| ADR-004 (area-saturation) | prompt / adr.md / cto-evaluation | AC-001..AC-030 (all) | D2 metric: ADR wrote boolean-first; spec encodes **overlap-weighted** | Binding decided-context + cto SIMPLIFY pick; ADR D2 itself names overlap-weighted as a same-loop drop-in (AC-004/005/010, ui-spec Deviation Log) |
| ADR-004 D1 (client-side h3-js) | adr.md | AC-011/012/013/014, AC-028 | none | aligned (no backend, moveend-debounced, bbox pre-filter) |
| ADR-004 D2 (coverage rule + self_conflict ignore) | adr.md | AC-004–009 | overlap-weighted (above) | aligned on the loop; metric extended per decided context |
| ADR-004 D3 (per-vertical, default none) | adr.md | AC-020/022/023 | none | aligned |
| ADR-004 D4 (H3HexagonLayer + zoom-adaptive res + z-order) | adr.md / ui-spec | AC-010/017/018 | none | aligned |
| ADR-004 D5 (prospecting) | adr.md / ui-spec §7 | AC-015/016/019 | none | aligned |
| ADR-004 D6 (no migration) | adr.md | AC-030 | none | aligned (no db-migration-reviewer gate) |
| ADR-004 risk: effective-radius drift | adr.md / cto | AC-001/002/003 | none | shared `effectiveRadiusMi` helper + parity test, the recommended mitigation |
| ADR-001/002/003 (W1/W2/W3 foundation) | adr.md "Builds on" | see Dependencies | none | read-only consumption of shipped substrate |

## Dependencies

- **W1 (ADR-001):** PostGIS multi-tenant + RLS (`auth_tenant_ids()`), deck.gl/MapLibre `MapShell` reactive
  overlay seam. W4 extends the overlay array; no W1 source change.
- **W2 (ADR-002):** customer→site, per-site geocoding, the `site_geo` view, `CustomerList`/`Form`/`Import`
  (the write path for the `site_geo` rows W4 reads), `sitePinsLayer`. No W2 source change.
- **W3 (ADR-003):** per-site `exclusivity_radius_mi` + `is_zone_on`, `customer.vertical`, `VERTICAL_OPTIONS`,
  `siteZonesLayer` (refactored to share `effectiveRadiusMi` — AC-002), the effective-radius rule, the
  lifted-state pattern. W4 only READS the stable `site_geo` contract + the effective-radius rule; the only
  W3 source change is the helper refactor of `siteZonesLayer.ts`. Cross-wave seam is read-only/additive →
  standalone single-wave `/orchestrated` build, no `crossWavePrior`, architect-final NOT required (ADR
  closing note).
- **External:** new direct dependency `h3-js` (AC-028); `H3HexagonLayer` via the existing `deck.gl ^9.3.5`
  umbrella; OpenFreeMap `liberty` basemap (W1, unchanged).
