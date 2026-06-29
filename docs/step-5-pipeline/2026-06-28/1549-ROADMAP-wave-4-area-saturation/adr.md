# ADR-004: Area-Saturation Heatmap — Client-Side H3 Tessellation Over the Already-Loaded Tenant Zone Set; In-Any-Zone Per-Vertical Coverage; No Migration

**Status:** Proposed
**Date:** 2026-06-28
**Feature:** area-saturation (Wave 4)
**Spec:** docs/step-3-specs/hex-grid/waves/area-saturation/area-saturation.md
**Builds on:** ADR-001 (foundation), ADR-002 (customers-geocoding), ADR-003 (`docs/step-5-pipeline/2026-06-28/1056-ROADMAP-wave-3-exclusivity-engine/adr.md`)

## Context

Wave 4 is the hex payoff: a saturation heatmap answering "how locked-up is this territory" and a prospecting view ("open area near here"). The substrate W3 shipped is the key constraint and the key opportunity:

- `App.tsx` already loads the **entire tenant's** `site_geo` rows into in-memory state (`sites`), each carrying `lat/lng/exclusivity_radius_mi/is_zone_on/vertical` — RLS-auto-scoped, refreshed on every data change (`App.tsx:58-99`).
- `MapShell.tsx` mounts a deck.gl `MapboxOverlay` and reactively rebuilds its layer array on data change (`[siteZonesLayer, sitePinsLayer]`, zones under pins — `MapShell.tsx:64-68`).
- W3's effective-zone rule is `is_zone_on ? coalesce(exclusivity_radius_mi,0) : 0` miles, `> 0`, replicated in both the conflict RPC (`0003/0004`) and `siteZonesLayer.ts:34-41`.
- `VERTICAL_OPTIONS` (`customers.ts:70-80`) is the controlled 8-token vertical vocabulary; `vertical` is the conflict/coverage key.
- `deck.gl ^9.3.5`; **no `h3-js` dep yet**. PostGIS posture: spatial *write-gating* truth lives in `security_invoker` RPCs.

Saturation is a **derived read-only visualization**, not a write-gating business rule — this distinction drives every decision below.

## Decision

Compute saturation **client-side with `h3-js`** over the already-loaded `sites` array; render via a deck.gl `H3HexagonLayer` mounted as the base wash in the existing reactive overlay. **No migration, no RPC, no new RLS surface.**

### Decisions list (load-bearing)

1. **Compute = client-side `h3-js`** over the in-memory tenant zone set, recomputed on viewport-idle (`moveend`), NOT server-side. (D1)
2. **Coverage metric = in-any-zone boolean** (cell centroid within any active same-vertical effective zone); overlap-weighted is a drop-in extension. (D2)
3. **Per-vertical** (OD-1): a vertical selector filters the zone set; no heatmap until a vertical is chosen. (D3)
4. **`H3HexagonLayer`, zoom-adaptive resolution**, data shape `{ h3, coverage }[]`; mounted UNDER zones+pins. New direct dep `h3-js`. (D4)
5. **Prospecting = highlight zero-coverage cells in the viewport**, ranked by distance to viewport center (MVP). (D5)
6. **No migration 0005.** (D6)
7. **`self_conflict` is irrelevant to saturation** — coverage counts every active zone regardless of owner. (D2)

### D1 — Compute location: client-side h3-js (THE load-bearing call)

The whole tenant zone set is **already in `App.sites`**. Coverage is therefore a pure in-memory function — no new query per viewport, no round trip on pan/zoom. Mechanism:

1. On `moveend` (debounced ~200 ms), read the map bounds; pad ~20%.
2. `polygonToCells(paddedBboxPolygon, res)` (h3-js) → candidate cell ids for the viewport.
3. Pre-filter zones to the padded bbox + the selected vertical (cheap array filter).
4. For each cell: `cellToLatLng(cell)` → centroid; mark covered iff `∃` zone where `haversineMi(centroid, zone) <= eff(zone)`.
5. Emit `{ h3, coverage }[]` → `H3HexagonLayer`.

Cost is `O(cells × zonesInViewport)`. At res 7 a metro viewport is ~hundreds–low-thousands of cells; with the bbox zone pre-filter and a tenant set in the hundreds, a recompute is well under a frame's worth of work — and it runs on `moveend`, **never per render/per frame** (mirrors W3's "recompute on data change, not per frame", `App.tsx:21-24`). The W3 GIST index is *not* needed: it serves server-side `ST_DWithin`; the client set is already tenant-scoped and resident.

**Reconciled with the performance-reviewer gate:** the gate confirms (a) recompute is `moveend`-debounced, not per-frame; (b) a hard cell-count cap per recompute (skip/raise resolution above the cap); (c) zones pre-filtered to the padded viewport bbox before the inner loop; (d) `updateTriggers` keyed on `{selectedVertical, dataVersion, resolution}` so deck.gl re-evaluates only on real change.

**Why not server-side:** an `h3-pg` extension is not guaranteed enabled on the Supabase project (operational dependency), and a PostGIS `ST_HexagonGrid`/`ST_Coverage` RPC would add a network round trip on *every* pan/zoom while re-deriving data the client already holds. Server-side wins only past the **scale tripwire** (~10k+ sites, where shipping the full tenant set to the client gets heavy) — recorded as the future-migration path, not this wave's choice.

### D2 — Coverage metric: in-any-zone boolean

Per-cell `coverage = 1` iff its centroid lies within the **effective** radius of any active zone of the **selected vertical**:

```
eff(s) = (s.is_zone_on ? (s.exclusivity_radius_mi ?? 0) : 0)   // miles
covered(cell) = sites.some(s =>
  s.vertical === selectedVertical &&
  eff(s) > 0 &&
  haversineMi(cellToLatLng(cell), {lat:s.lat, lng:s.lng}) <= eff(s))
```

This is exactly W3's effective-zone rule (`siteZonesLayer.ts:34-41`) — it MUST be factored into one shared `effectiveRadiusMi(site)` helper so the heatmap and the W3 circles can never drift. Centroid-in-circle is a deliberate per-cell approximation of geodesic-circle coverage; error shrinks with resolution and is acceptable for a wash-style aggregate.

**`self_conflict` does NOT participate.** That flag governs whether a brand conflicts with *itself* in pairwise conflict detection (`0004`). Saturation measures *territory coverage of the vertical* — every active zone consumes territory regardless of owner. State explicitly: the coverage loop ignores `customer_id` and `self_conflict`.

**Overlap-weighted extension (deferred, drop-in):** replace `.some(...)` with a count of covering zones → `coverage: number` density; the color ramp keys on the count. Same loop, same data, no new inputs. Recommended as the v2 cut once the boolean ships.

### D3 — Per-vertical (default, OD-1)

A per-vertical heatmap. A combined all-verticals wash is misleading — a gas zone does not saturate a grocery prospect. Mechanism:

- New App state `selectedVertical: string | null`, lifted to `MapShell` (same pattern as `conflictIds`, `App.tsx:53-56`).
- A `<select>` over `VERTICAL_OPTIONS` (`customers.ts:70-80`) — reuse the vocabulary, do not re-author it.
- Filter: `sites.filter(s => s.vertical === selectedVertical)` feeds the coverage loop.
- **Default = none selected → no heatmap layer** (the H3 layer is omitted until a vertical is chosen). Keeps the first paint identical to W3 and avoids an arbitrary default vertical.

### D4 — H3 resolution + the deck.gl layer

`H3HexagonLayer` (from the `deck.gl` umbrella, which re-exports `@deck.gl/geo-layers`; `h3-js` added as a **direct** dependency for `polygonToCells`/`cellToLatLng`). **Zoom-adaptive resolution** so cell size tracks zoom and the cell budget stays bounded:

| map zoom | H3 res |
|---|---|
| < 5 | 4 |
| 5–7 | 6 |
| 8–10 | 7 |
| > 10 | 8 |

Data shape the client builds: `{ h3: string; coverage: number }[]`. Layer config: `getHexagon: d => d.h3`, `extruded: false`, `filled: true`, `stroked: false`, `pickable: false`, `getFillColor` = a coverage→color ramp (transparent at 0; a single hue ramping alpha for the boolean cut, e.g. reuse the `[176,0,32]`/`[21,88,176]` palette family), `updateTriggers` per D1.

**Reuse the MapShell reactive overlay:** add a `saturationLayer(cells)` builder (new `src/components/saturationLayer.ts`, mirroring `siteZonesLayer.ts`). Mount it FIRST in the overlay array — `[saturationLayer, siteZonesLayer, sitePinsLayer]` — so the wash sits *under* the zones and pins. Extend the `MapShell` props + the reactive effect (`MapShell.tsx:64-68`) to carry the cell set.

### D5 — Prospecting view ("open area near here")

MVP, no new data: a toggle that highlights the **zero-coverage** cells already computed for the viewport. Mechanism: from the same `{ h3, coverage }[]`, take `coverage === 0` cells, rank by `haversineMi(cellToLatLng(cell), viewportCenter)`, and render the top-N as a distinct `H3HexagonLayer` style (e.g. green stroke). Because the cells are already viewport-bounded, "near here" is intrinsic. An optional "jump to nearest open area" button pans to the nearest zero-coverage cell's centroid. No prospecting *persistence* this wave.

### D6 — Migration shape (0005)

**NONE.** The feature reads only `site_geo` (already loaded, already RLS-scoped) and computes in the browser. No table, no view change, no RPC, no index. This also means **no `db-migration-reviewer` gate** is required — matching the skeleton's named gates (performance-reviewer · code-reviewer).

*If server-side were ever chosen* (scale tripwire): a single `security_invoker`, tenant-scoped, pure-reporting RPC returning `(h3 text, coverage int)` for a bbox+vertical+resolution, additive/forward-only/reversible, mirroring `0003`'s grant-tightening exactly. Explicitly out of scope for W4.

## Consequences

### Benefits
- Zero new migration, zero new RLS surface to audit — the feature inherits W3's tenant isolation by reading the already-scoped in-memory set. The lowest-risk possible posture for a read-only aggregate.
- Reuses the in-memory tenant zone set, the W3 effective-radius rule, the `VERTICAL_OPTIONS` vocabulary, and the MapShell reactive-overlay pattern — minimal new surface (`saturationLayer.ts` + one helper + selector/toggle state).
- Recompute is `moveend`-debounced and viewport-bounded; no per-frame and no per-pan network cost.

### Tradeoffs
- Centroid-in-circle is a per-cell approximation of geodesic coverage; finer resolution reduces edge error. Acceptable for a wash, not for a legal boundary.
- The full tenant zone set must be client-resident (it already is under W3). Past ~10k sites this becomes the scale tripwire toward a server-side RPC.
- Boolean coverage first; density (overlap-weighted) is a follow-on.

### Risks
- **Client/server effective-radius drift.** The heatmap re-implements W3's `eff` rule in JS. **Recommended mitigation:** factor `effectiveRadiusMi(site)` into one shared helper consumed by both `siteZonesLayer` and the coverage loop; a unit test asserts parity with the `0003/0004` predicate constants (`1609.344`, `is_zone_on` fold). **Alternative if drift recurs:** move compute server-side (D6 tripwire path).
- **Cell-count blow-up at low zoom / large bbox.** Mitigation: zoom-adaptive resolution (D4) + a hard per-recompute cell cap (raise resolution / skip above it); performance-reviewer confirms the cap and the `moveend` cadence via a worst-case (CONUS-zoom, max sites) measurement.
- **`H3HexagonLayer` peer/runtime dep.** `h3-js` must be an explicit dependency, not relied on transitively. Mitigation: add to `package.json` dependencies; dependency-auditor optional.

## Implementation Notes

### Migration Safety
- None (D6). Nothing to reverse, backfill, or deploy.

### Testing Strategy
- **Unit (coverage):** a cell centroid 0.4 mi from a 0.5 mi active same-vertical zone ⇒ covered; 0.6 mi ⇒ not; zone `is_zone_on=false` or null radius ⇒ never covers; a different-vertical zone ⇒ never covers; `self_conflict` true/false ⇒ identical coverage (owner-independent).
- **Unit (eff parity):** `effectiveRadiusMi` matches the W3 predicate for the off/null/zero/positive cases.
- **Integration:** changing `selectedVertical` swaps the cell set; `moveend` recomputes; data reload (`reload`) re-derives without a page reload.
- **Manual:** heatmap sits under zones+pins; prospecting highlights zero-coverage viewport cells; resolution steps with zoom.

### Performance Considerations
- Recompute on `moveend` only, debounced ~200 ms; never per frame/render.
- Pre-filter zones to padded viewport bbox before the inner loop; cap cells per recompute; zoom-adaptive resolution.
- `updateTriggers` keyed on `{selectedVertical, dataVersion, resolution}`.

## Alternatives Considered

### Server-side compute (h3-pg extension or PostGIS ST_HexagonGrid RPC)
Rejected for this wave. `h3-pg` is not guaranteed enabled (operational dependency); a PostGIS grid RPC adds a network round trip on every pan/zoom to re-derive data the client already holds. Reserved as the >10k-site scale tripwire (D6).

### Overlap-weighted density as the first cut
Deferred. The boolean in-any-zone metric ships the "locked-up?" answer with the simplest ramp and the least tuning; density is a same-loop drop-in extension once the boolean is validated.

### Combined all-verticals heatmap
Rejected as the default. Cross-vertical territory does not compete; a combined wash conflates unrelated coverage. Per-vertical (OD-1) is the correct grain; combined could later be an explicit "all" option if a use case appears.

### Reusing `siteZonesLayer` circles as the saturation viz
Rejected. Circles show *individual* zones, not aggregate territory lock-up; H3 cells are the aggregation primitive the wave exists to deliver and the substrate for prospecting.

## Spec Issues Found

### Blockers (must fix before implementation)
- **None.** Every read is `site_geo` (built, W2/W3) already loaded into `App.sites`; the selected-vertical input is `VERTICAL_OPTIONS` (built); no entity lacks a source.

### Recommendations (should fix)
- **Name the shared `effectiveRadiusMi` helper as an explicit ticket** so the heatmap and W3 circles consume one rule (drift risk above). pm-spec should make this a named atom, not an implicit refactor.
- **Decide the zero-coverage threshold for prospecting** — strictly `coverage === 0` vs "below low density." For the boolean cut, `=== 0` is the only option; flag for when overlap-weighted lands.

### Notes (FYI for implementer)
- Defer metro/ZIP aggregation — ZIP overlay is Wave 5 (reference-overlays), per the kickoff. W4 ships viewport heatmap + prospecting only.
- Mount order in `MapShell` overlay array is load-bearing: `[saturationLayer, siteZonesLayer, sitePinsLayer]` (wash under zones under pins).
- `H3HexagonLayer` imports from `deck.gl` (umbrella, as `ScatterplotLayer` already does); `h3-js` is the new direct dep.
- Cross-wave seam (W3 → W4): W4 only *reads* the stable `site_geo` view contract + the effective-radius rule. Read-only, additive, no W3 source change. This is a standalone single-wave `/orchestrated` build — no `crossWavePrior`, architect-final not required.
