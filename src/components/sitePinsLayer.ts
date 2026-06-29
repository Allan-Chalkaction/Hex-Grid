import { ScatterplotLayer } from 'deck.gl';
import type { SiteGeo } from '../lib/customers';
import { VERTICAL_COLORS, VERTICAL_NEUTRAL, type RGB } from '../lib/verticalStyle';

/**
 * The site-pins deck.gl layer (W1 AC-010 + RO-T2 — AC-004/005/006).
 *
 * Builds a `ScatterplotLayer` from `site_geo` rows. Sites without a location
 * (failed/pending geocode → null lat/lng) are filtered out, so only located
 * sites render as pins. A newly-added/geocoded site appears as a pin once the
 * lifted map state refreshes (the reactive seam in `MapShell` + `App`).
 *
 * Wave 5 adds:
 *   - **Always-on color-by-vertical** — `getFillColor` resolves each pin's
 *     `d.vertical` through the stable `VERTICAL_COLORS` palette (neutral grey for
 *     `null`/unknown), regardless of selection or filter state (AC-004). The fill
 *     is OPAQUE (3-tuple, no alpha — mirrors the old `[21,88,176]`) so a pin reads
 *     crisply over the translucent wash/zones; the 1px white stroke is the
 *     graphical-separation cue.
 *   - **Opt-in single-vertical filter** — when `filterToVertical` is on AND a
 *     vertical is selected, `data` pre-filters to that vertical's located sites;
 *     otherwise all located sites render (AC-005). Coloring applies to the visible
 *     set either way.
 *
 * `id` stays `'site-pins'` and the `updateTriggers.getFillColor` key is the
 * CONSTANT `'vertical-palette-v1'` (the palette is static; the redraw is driven
 * by the layer rebuild on `sites`/`selectedVertical`/`filterToVertical` change —
 * never per frame) (AC-006).
 */
export interface SitePinsOptions {
  selectedVertical: string | null;
  filterToVertical: boolean;
}

export function sitePinsLayer(
  sites: SiteGeo[],
  { selectedVertical, filterToVertical }: SitePinsOptions = {
    selectedVertical: null,
    filterToVertical: false,
  },
): ScatterplotLayer<LocatedSite> {
  const located: LocatedSite[] = sites.filter(
    (s): s is LocatedSite => s.lat != null && s.lng != null,
  );

  // AC-005: filter to the selected vertical ONLY when the opt-in is on AND a
  // vertical is selected; otherwise every located pin renders (still colored).
  const visible: LocatedSite[] =
    filterToVertical && selectedVertical
      ? located.filter((s) => s.vertical === selectedVertical)
      : located;

  return new ScatterplotLayer<LocatedSite>({
    id: 'site-pins',
    data: visible,
    getPosition: (d) => [d.lng, d.lat],
    getRadius: 6,
    radiusUnits: 'pixels',
    radiusMinPixels: 4,
    // AC-004: opaque per-vertical fill via the stable palette; neutral for null.
    getFillColor: (d): RGB => VERTICAL_COLORS[d.vertical ?? ''] ?? VERTICAL_NEUTRAL,
    stroked: true,
    getLineColor: [255, 255, 255],
    lineWidthUnits: 'pixels',
    getLineWidth: 1,
    pickable: true,
    // AC-006: a CONSTANT trigger key — the palette is static, so the recolor only
    // needs to re-run when the layer is rebuilt (data/selection change), never per
    // frame. Mirrors the siteZonesLayer `conflictKey` idiom with a fixed value.
    updateTriggers: {
      getFillColor: 'vertical-palette-v1',
    },
  });
}

/** A `site_geo` row that has a resolved location. */
type LocatedSite = SiteGeo & { lat: number; lng: number };
