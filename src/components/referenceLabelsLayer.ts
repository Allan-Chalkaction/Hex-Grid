import { TextLayer } from 'deck.gl';
import { CollisionFilterExtension } from '@deck.gl/extensions';

/**
 * Capitals + metros reference-label factories (RO-T3 — AC-007..011).
 *
 * Two deck.gl `TextLayer` builders mirroring the per-file layer-factory shape
 * (`sitePinsLayer` / `siteZonesLayer` / `saturationLayer`). `TextLayer` imports
 * from the `deck.gl` umbrella exactly as `ScatterplotLayer` / `H3HexagonLayer`
 * do. Both render the place name at its position with a **white sdf halo** (the
 * load-bearing legibility mechanism over basemap + pins + wash — the named
 * ui-review gate), anchored ABOVE the point, `pickable: false` (labels are
 * passive; pins own picking, ZCTA picking is MapLibre-native).
 *
 * Two visual tiers (ui-spec §5): capitals are bolder/darker/larger (the more
 * important reference tier); metros are smaller/greyer/normal-weight.
 *
 * Clutter control for metros (~129 points): a min-zoom gate (`shouldShowMetros`,
 * consumed by MapShell's conditional spread) + deck.gl's
 * `CollisionFilterExtension`. Capitals carry the SAME extension + a HIGHER
 * `getCollisionPriority` in a shared collision group, so a capital label wins a
 * collision against an overlapping metro (the rationale for capitals being the
 * last/top layer in the overlay array). If the extension ever proves heavy, the
 * min-zoom gate alone is the documented acceptable fallback (AC-011 / ADR-005).
 */

export interface CapitalRow {
  name: string;
  state: string;
  lat: number;
  lng: number;
}

export interface MetroRow {
  name: string;
  lat: number;
  lng: number;
  pop: number;
}

/** Shared text/halo config both tiers carry (white sdf halo = legibility). */
const SHARED = {
  getText: (d: CapitalRow | MetroRow): string => d.name,
  getPosition: (d: CapitalRow | MetroRow): [number, number] => [d.lng, d.lat],
  sizeUnits: 'pixels' as const,
  // White sdf halo — readable over a light street, a dark park, or a colored pin.
  fontSettings: { sdf: true },
  outlineWidth: 2,
  outlineColor: [255, 255, 255, 255] as [number, number, number, number],
  // Anchor the label ABOVE its point so the dot location is not obscured.
  getTextAnchor: 'middle' as const,
  getAlignmentBaseline: 'bottom' as const,
  getPixelOffset: [0, -2] as [number, number],
  pickable: false,
};

/**
 * The CollisionFilterExtension props, spread into each layer config. They are
 * not part of deck.gl's static `TextLayerProps` type (an extension augments props
 * at runtime), so they ride in via a spread (excess-property checking does not
 * apply to spread members). Capitals + metros share one `collisionGroup` so a
 * high-priority capital label wins a collision over a lower-priority metro.
 */
function collisionProps(priority: number) {
  return {
    extensions: [new CollisionFilterExtension()],
    collisionGroup: 'reference-labels',
    getCollisionPriority: priority,
  };
}

/**
 * Capitals tier (50, sparse) — near-black `[40,40,40]`, 13px, bold (700); render
 * at all zooms (no min-zoom gate). Highest collision priority so a capital wins.
 */
export function capitalsLayer(data: CapitalRow[]): TextLayer<CapitalRow> {
  return new TextLayer<CapitalRow>({
    ...SHARED,
    ...collisionProps(10),
    id: 'reference-capitals',
    data,
    getSize: 13,
    getColor: [40, 40, 40],
    fontWeight: 700,
  });
}

/**
 * Metros tier (~129) — dark grey `[85,85,85]` (#555), 11px, normal (400). Gated
 * below ~zoom 5 by `shouldShowMetros` (MapShell's spread condition) + collision-
 * filtered; lower collision priority than capitals.
 */
export function metrosLayer(data: MetroRow[]): TextLayer<MetroRow> {
  return new TextLayer<MetroRow>({
    ...SHARED,
    ...collisionProps(0),
    id: 'reference-metros',
    data,
    getSize: 11,
    getColor: [85, 85, 85],
    fontWeight: 400,
  });
}

/**
 * The metro min-zoom predicate (AC-011). MapShell omits `metrosLayer` from the
 * overlay array when this is false, so ~129 metro labels never flood the map at
 * low zoom (the toggle being on does not force a render below the gate).
 */
export function shouldShowMetros(zoom: number): boolean {
  return zoom >= 5;
}
