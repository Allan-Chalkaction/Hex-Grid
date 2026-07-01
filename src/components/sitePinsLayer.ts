import { ScatterplotLayer, type PickingInfo } from 'deck.gl';
import type { SiteGeo } from '../lib/customers';
import { VERTICAL_COLORS, VERTICAL_NEUTRAL, type RGB } from '../lib/verticalStyle';

/**
 * The site-pins deck.gl layer (W1 AC-010 + RO-T2 → CG redesign).
 *
 * Builds a `ScatterplotLayer` from `site_geo` rows. Sites without a location
 * (failed/pending geocode → null lat/lng) are filtered out, so only located
 * sites render as pins. A newly-added/geocoded site appears as a pin once the
 * lifted map state refreshes (the reactive seam in `MapShell` + `App`).
 *
 * The left-menu redesign makes the **multi-select vertical chooser the gate** for
 * site visibility (replacing the W5 always-on pins + opt-in single-vertical
 * filter):
 *   - **`selectedVerticals` drives the visible set** — only located sites whose
 *     `vertical` ∈ `selectedVerticals` render. The DEFAULT is the empty set →
 *     NO pins (just the basemap); a pin appears the moment its vertical is
 *     checked. Pins are still colored by vertical via the stable palette.
 *   - **Color-by-vertical** — `getFillColor` resolves each visible pin's
 *     `d.vertical` through `VERTICAL_COLORS` (neutral grey for `null`/unknown).
 *     The fill is OPAQUE (3-tuple, no alpha) so a pin reads crisply over the
 *     translucent wash/zones; the 1px white stroke is the separation cue.
 *
 * `id` stays `'site-pins'` and the `updateTriggers.getFillColor` key is the
 * CONSTANT `'vertical-palette-v1'` (the palette is static; the redraw is driven
 * by the layer rebuild on `sites`/`selectedVerticals` change — never per frame).
 */
export interface SitePinsOptions {
  selectedVerticals: string[];
  /**
   * Optional deck.gl hover callback (CG hover card). When supplied it is wired
   * to the pickable ScatterplotLayer; deck fires it with the picking `info`
   * ({ object, x, y, picked }) on pointer move over / off a pin. MapShell lifts
   * the hovered site + pointer coords into React state to render the visual,
   * `pointer-events:none` card. Omitted (the default) → no hover behavior.
   */
  onHover?: (info: PickingInfo) => void;
}

export function sitePinsLayer(
  sites: SiteGeo[],
  { selectedVerticals, onHover }: SitePinsOptions = { selectedVerticals: [] },
): ScatterplotLayer<LocatedSite> {
  const located: LocatedSite[] = sites.filter(
    (s): s is LocatedSite => s.lat != null && s.lng != null,
  );

  // The multi-select IS the gate: only located sites whose vertical is one of
  // the selected verticals render. Empty selection → empty pin set (default
  // load shows no sites — just the basemap).
  const visible: LocatedSite[] = located.filter(
    (s) => s.vertical != null && selectedVerticals.includes(s.vertical),
  );

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
    // `pickable` makes the pins hoverable; `onHover` (when supplied) lifts the
    // hovered site + pointer coords for the info card. A canvas hover is a
    // mouse-only convenience — the accessible data path is the Sites table /
    // customer list (same posture as the ZCTA click popup); the card itself is
    // aria-hidden + pointer-events:none so it never affects keyboard/SR users.
    pickable: true,
    onHover,
    // A CONSTANT trigger key — the palette is static, so the recolor only needs
    // to re-run when the layer is rebuilt (data/selection change), never per
    // frame. Mirrors the siteZonesLayer `conflictKey` idiom with a fixed value.
    updateTriggers: {
      getFillColor: 'vertical-palette-v1',
    },
  });
}

/** A `site_geo` row that has a resolved location. */
type LocatedSite = SiteGeo & { lat: number; lng: number };
