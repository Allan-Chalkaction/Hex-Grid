import { ScatterplotLayer } from 'deck.gl';
import type { SiteGeo } from '../lib/customers';

/**
 * The site-pins deck.gl layer (AC-010).
 *
 * Builds a `ScatterplotLayer` from `site_geo` rows. Sites without a location
 * (failed/pending geocode → null lat/lng) are filtered out, so only located
 * sites render as pins. A newly-added/geocoded site appears as a pin once the
 * lifted map state refreshes (the reactive seam in `MapShell` + `App`).
 */
export function sitePinsLayer(sites: SiteGeo[]): ScatterplotLayer<LocatedSite> {
  const located: LocatedSite[] = sites.filter(
    (s): s is LocatedSite => s.lat != null && s.lng != null,
  );

  return new ScatterplotLayer<LocatedSite>({
    id: 'site-pins',
    data: located,
    getPosition: (d) => [d.lng, d.lat],
    getRadius: 6,
    radiusUnits: 'pixels',
    radiusMinPixels: 4,
    getFillColor: [21, 88, 176], // #1558b0
    stroked: true,
    getLineColor: [255, 255, 255],
    lineWidthUnits: 'pixels',
    getLineWidth: 1,
    pickable: true,
  });
}

/** A `site_geo` row that has a resolved location. */
type LocatedSite = SiteGeo & { lat: number; lng: number };
