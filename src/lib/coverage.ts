import type { SiteGeo } from './customers';

/**
 * Area-saturation coverage core (Wave 4 — AS-T1+).
 *
 * The pure, vitest-covered heart of the saturation feature: the shared
 * effective-radius rule (AS-T1), and — added in AS-T2 — the zoom→resolution
 * map, the haversine metric, and the viewport tessellation + overlap-weighted
 * coverage compute. NO supabase / network here; it operates only on the
 * already-loaded, already-RLS-scoped `site_geo` rows in `App.sites` (ADR-004 D1,
 * AC-030).
 */

/**
 * AS-T1 / AC-001 — the single shared effective-radius rule (miles).
 *
 * `effectiveRadiusMi(site) = is_zone_on ? (exclusivity_radius_mi ?? 0) : 0`.
 *
 * This is the EXACT W3 effective-zone rule that `siteZonesLayer` used to inline
 * (`is_zone_on && exclusivity_radius_mi != null && > 0`). Factoring it into one
 * helper consumed by BOTH the W3 zone circles (AC-002) AND the W4 coverage
 * compute (AC-004+) is the drift-kill the ADR risk section mandates: a site has
 * an effective zone (draws a W3 circle / contributes to coverage) iff this
 * returns `> 0`, and the rendered circle radius in meters is exactly this value
 * `× 1609.344` (the constant `siteZonesLayer.ts` renders with — AC-003 parity).
 *
 * Structurally owner-independent: it reads only `is_zone_on` +
 * `exclusivity_radius_mi`, never `customer_id`/`self_conflict` (AC-008).
 */
export function effectiveRadiusMi(
  site: Pick<SiteGeo, 'is_zone_on' | 'exclusivity_radius_mi'>,
): number {
  return site.is_zone_on ? (site.exclusivity_radius_mi ?? 0) : 0;
}

/**
 * The miles→meters constant the W3 `siteZonesLayer` renders zone circles with
 * (`siteZonesLayer.ts:52`, `radius_mi * 1609.344`). Exported so the parity test
 * (AC-003) and any future meters-consumer reference ONE source of truth — a
 * one-sided edit to either the helper or the layer breaks the parity test.
 */
export const MILES_TO_METERS = 1609.344;
