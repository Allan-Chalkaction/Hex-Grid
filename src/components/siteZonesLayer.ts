import { ScatterplotLayer } from 'deck.gl';
import type { SiteGeo } from '../lib/customers';

/**
 * The exclusivity-zone deck.gl layer (EX-T5 / AC-021).
 *
 * Draws a geodesically-accurate translucent circle per site that has an
 * EFFECTIVE zone — located (lat/lng set), `is_zone_on`, and a positive radius.
 * Off/null-radius sites are filtered out (no circle), mirroring the
 * `sitePinsLayer.ts` located-filter pattern. The circle radius is the ADR meters
 * conversion (`radius_mi * 1609.344`) so the picture equals the `ST_DWithin`
 * geography semantic.
 *
 * Coloring is keyed on `conflictIds` (derived from the conflict RPC on data
 * change, NOT a view column — ADR Decision 5): a conflict zone is red with a
 * THICKER stroke (a non-color cue), a clear zone is blue. RGBA literals reuse the
 * existing pin/error hues (`[21,88,176]` / `[176,0,32]`). The map color is
 * reinforcement only — the authoritative, SR-readable signal is the SiteRow
 * zone-status word+glyph (AC-022/AC-023).
 *
 * Mounted UNDER the pins in `MapShell` (zones first in the layers array), so a
 * circle never occludes its pin. `pickable:false` — the pins own picking.
 */
type ZonedSite = SiteGeo & {
  lat: number;
  lng: number;
  exclusivity_radius_mi: number;
};

export function siteZonesLayer(
  sites: SiteGeo[],
  conflictIds: Set<string>,
): ScatterplotLayer<ZonedSite> {
  const zoned: ZonedSite[] = sites.filter(
    (s): s is ZonedSite =>
      s.lat != null &&
      s.lng != null &&
      s.is_zone_on &&
      s.exclusivity_radius_mi != null &&
      s.exclusivity_radius_mi > 0,
  );

  // A stable key for deck.gl's accessor-memo so a recolor (new conflictIds set)
  // re-evaluates the color accessors even when the data array is unchanged.
  const conflictKey = Array.from(conflictIds).sort().join(',');

  return new ScatterplotLayer<ZonedSite>({
    id: 'site-zones',
    data: zoned,
    getPosition: (d) => [d.lng, d.lat],
    radiusUnits: 'meters',
    getRadius: (d) => d.exclusivity_radius_mi * 1609.344,
    stroked: true,
    filled: true,
    lineWidthUnits: 'pixels',
    getFillColor: (d): [number, number, number, number] =>
      conflictIds.has(d.id) ? [176, 0, 32, 46] : [21, 88, 176, 38],
    getLineColor: (d): [number, number, number, number] =>
      conflictIds.has(d.id) ? [176, 0, 32, 220] : [21, 88, 176, 200],
    getLineWidth: (d) => (conflictIds.has(d.id) ? 2 : 1),
    pickable: false,
    updateTriggers: {
      getFillColor: conflictKey,
      getLineColor: conflictKey,
      getLineWidth: conflictKey,
    },
  });
}
