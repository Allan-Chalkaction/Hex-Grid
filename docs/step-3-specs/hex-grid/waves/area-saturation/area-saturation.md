# Wave 4 — area-saturation (the hex payoff)

**Status:** ready-to-build (graduated 2026-06-28 via /roadmap Phase W). Plan artifacts:
`docs/step-5-pipeline/2026-06-28/1549-ROADMAP-wave-4-area-saturation/` (spec.md = 30 ACs, adr.md = ADR-004, ui-spec-addendum.md, findings/).

**Ships:** an H3 saturation heatmap ("how locked-up is this territory") + a prospecting "open area near here" view, computed from the W3 exclusivity zones.

## Locked decisions (ADR-004 + cto SIMPLIFY)
- **Client-side h3-js** — the whole tenant's `site_geo` is already in App memory, so saturation is a pure in-memory function. **No backend, no migration, no RLS surface.** (Server-side PostGIS-h3 deferred → scale tripwire.)
- **Coverage = overlap-weighted** — per-cell count of active same-vertical zones covering the cell centroid; `0` = open. (Gradient is the payoff; same compute loop as boolean.)
- **Shared `effectiveRadiusMi(site)` helper** (= `is_zone_on ? radius : 0`) consumed by BOTH the saturation compute AND W3's `siteZonesLayer` (refactor), with a parity test — kills client/server drift. `self_conflict` is IRRELEVANT to saturation.
- **Per-vertical** — vertical `<select>` (reuse `VERTICAL_OPTIONS`); default none → no heatmap.
- **deck.gl H3HexagonLayer** (`saturationLayer`), discrete Blues ramp (open / 1 / 2 / 3+), mounted UNDER zones+pins; legend + `aria-live` textual summary = the accessible path.
- **Prospecting** — zero-coverage cells near viewport center (`prospectLayer`, green outline); optional "jump to nearest open area".
- **Perf gate** — zoom-adaptive H3 resolution clamp + hard cell-count cap + debounced `moveend` + bbox pre-filter. New dep: `h3-js`.

## Scope
- **IN:** `effectiveRadiusMi` helper + siteZonesLayer refactor; `coverage.ts` (tessellate + overlap-weighted compute + resolution clamp + cell cap + prospect rank); `saturationLayer`/`prospectLayer`; MapShell mount + debounced viewport recompute; floating `.saturation-panel` (selector + heatmap/prospecting toggles + legend + summary); App wiring.
- **OUT (→ Wave 5 / later):** metro/ZIP aggregation (W5 reference-overlays owns ZIP); server-side PostGIS-h3 compute.

## Tickets (6 — see area-saturation-prompts.md)
AS-T1 effectiveRadiusMi helper + refactor + parity → AS-T2 coverage compute core + h3-js → AS-T3 saturation/prospect layers → AS-T4 MapShell mount + moveend → AS-T5 SaturationPanel + css → AS-T6 App wiring + jump.
Graph: T1 → T2 → T3 → T4; T5 (independent); T6 ← {T2,T4,T5}. 30 ACs (AC-001..030) covered.

## Gates
performance-reviewer (per-viewport hex compute — the named risk) · code-reviewer · + accessibility-auditor & ui-review on the panel/legend/visual tickets. **No db-migration-reviewer/security-auditor** (no migration/RPC/RLS surface).

## Depends on
Wave 1 (map shell, site.geog) · Wave 2 (site_geo, vertical field) · Wave 3 (exclusivity zones, `exclusivity_radius_mi`/`is_zone_on`/`vertical` on site_geo, siteZonesLayer, App in-memory sites). Read-only/additive on W3 (only W3 source change = the siteZonesLayer helper refactor).

## Open follow-ups carried forward
Metro/ZIP aggregation (W5); server-side authoritative saturation (embed-harden / scale); prospecting persistence + responsive panel collapse.
