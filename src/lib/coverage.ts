import { cellToLatLng, getHexagonAreaAvg, polygonToCells } from 'h3-js';
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

// ---------------------------------------------------------------------------
// AS-T2 — the viewport tessellation + overlap-weighted coverage compute core.
// Pure, vitest-covered, NO supabase (AC-030): it operates only on the already-
// loaded `App.sites` rows + the current viewport. ADR-004 D1/D2; AC-004..015.
// ---------------------------------------------------------------------------

/** A WGS84 point. */
export interface LatLng {
  lat: number;
  lng: number;
}

/** A map viewport bounding box (WGS84 degrees). */
export interface ViewportBounds {
  west: number;
  south: number;
  east: number;
  north: number;
}

/** One coverage cell: an H3 index + its overlap-weighted zone count. */
export interface CoverageCell {
  h3: string;
  coverage: number;
}

/** The full result of a viewport coverage recompute (consumed by App/MapShell). */
export interface SaturationResult {
  /** Covered cells (`coverage >= 1`) — the `saturationLayer` data set. */
  cells: CoverageCell[];
  /** Top-N nearest open cells (`coverage === 0`) — the `prospectLayer` data set. */
  openCells: CoverageCell[];
  /** Count of covered cells in view (for the textual summary). */
  coveredCount: number;
  /** Count of open (zero-coverage) cells in view (for the textual summary). */
  openCount: number;
  /** True when the viewport exceeded the cell cap — surfaces "Zoom in to compute". */
  capped: boolean;
  /** The H3 resolution used (for `updateTriggers`). */
  resolution: number;
}

/** Mean Earth radius in miles (haversine). */
const EARTH_RADIUS_MI = 3958.7613;

/** Default hard per-recompute candidate-cell cap (AC-011). */
export const DEFAULT_CELL_CAP = 6000;

/** Default padded-bbox fraction (~20% per ADR D1 step 1). */
export const DEFAULT_PAD_FRACTION = 0.2;

/** Default top-N nearest open cells the prospecting layer renders (AC-015). */
export const DEFAULT_PROSPECT_N = 30;

/**
 * AS-T2 / AC-010 — zoom-adaptive H3 resolution (ADR D4 table), clamped at the
 * bounds: zoom <5 → 4, 5–7 → 6, 8–10 → 7, >10 → 8. Out-of-range / non-finite
 * inputs clamp (zoom 0 → 4, zoom 22 → 8).
 */
export function resolutionForZoom(zoom: number): number {
  if (!Number.isFinite(zoom) || zoom < 5) {
    return 4;
  }
  if (zoom <= 7) {
    return 6;
  }
  if (zoom <= 10) {
    return 7;
  }
  return 8;
}

/**
 * Great-circle distance in miles between two WGS84 points (haversine). This is
 * the centroid-in-circle membership metric (AC-009): a cell centroid is "in" a
 * zone iff `haversineMi(centroid, site) <= effectiveRadiusMi(site)`.
 */
export function haversineMi(a: LatLng, b: LatLng): number {
  const toRad = (d: number): number => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const lat1 = toRad(a.lat);
  const lat2 = toRad(b.lat);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_MI * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Pad a bbox outward by `frac` of its span on each axis (ADR D1 step 1). */
function padBounds(b: ViewportBounds, frac: number): ViewportBounds {
  const dLat = (b.north - b.south) * frac;
  const dLng = (b.east - b.west) * frac;
  return {
    south: b.south - dLat,
    north: b.north + dLat,
    west: b.west - dLng,
    east: b.east + dLng,
  };
}

/** Is a point inside a bbox (inclusive)? */
function inBounds(p: LatLng, b: ViewportBounds): boolean {
  return p.lat >= b.south && p.lat <= b.north && p.lng >= b.west && p.lng <= b.east;
}

/** The h3-js polygon loop for a bbox: a single outer ring of [lat, lng] pairs. */
function bboxLoop(b: ViewportBounds): number[][][] {
  return [
    [
      [b.south, b.west],
      [b.south, b.east],
      [b.north, b.east],
      [b.north, b.west],
    ],
  ];
}

/**
 * Cheap candidate-cell estimate for the cap guard (AC-011): bbox area / mean H3
 * hex area at `res`. Lets the cap reject a CONUS-scale low-zoom bbox WITHOUT
 * tessellating it (the explosion the perf gate names) — `polygonToCells` is
 * never called when the estimate is over cap.
 */
function estimateCandidateCells(b: ViewportBounds, res: number): number {
  const latKm = (b.north - b.south) * 110.574;
  const midLat = ((b.north + b.south) / 2) * (Math.PI / 180);
  const lngKm = (b.east - b.west) * 111.32 * Math.cos(midLat);
  const areaKm2 = Math.abs(latKm * lngKm);
  const hexAreaKm2 = getHexagonAreaAvg(res, 'km2');
  return areaKm2 / hexAreaKm2;
}

/** Overlap-weighted coverage for one cell against an already-filtered zone set. */
function cellCoverage(h3: string, activeZones: SiteGeo[]): number {
  const [lat, lng] = cellToLatLng(h3);
  const centroid: LatLng = { lat, lng };
  let n = 0;
  for (const z of activeZones) {
    if (
      haversineMi(centroid, { lat: z.lat as number, lng: z.lng as number }) <=
      effectiveRadiusMi(z)
    ) {
      n++;
    }
  }
  return n;
}

/**
 * AS-T2 / AC-004..009 — overlap-weighted coverage for an EXPLICIT cell list.
 *
 * Filters `sites` to the selected vertical + effective (positive) zones +
 * located before the inner loop, then counts, per cell, how many of those zones
 * cover the cell centroid. The coverage is a COUNT, not a boolean (AC-004); a
 * cell outside every zone is `0` (AC-005); other-vertical zones never contribute
 * (AC-006); off/null/zero-radius zones never contribute via `effectiveRadiusMi`
 * (AC-007); `customer_id`/`self_conflict` are never read so coverage is
 * owner-independent (AC-008); membership is centroid-in-circle (AC-009).
 *
 * Exposed (separate from `computeSaturation`) so unit tests can pin coverage on
 * a chosen cell centroid without depending on viewport tessellation.
 */
export function coverageForCells(
  h3Cells: string[],
  sites: SiteGeo[],
  selectedVertical: string,
): CoverageCell[] {
  const active = sites.filter(
    (s) =>
      s.vertical === selectedVertical &&
      effectiveRadiusMi(s) > 0 &&
      s.lat != null &&
      s.lng != null,
  );
  return h3Cells.map((h3) => ({ h3, coverage: cellCoverage(h3, active) }));
}

/**
 * AS-T2 / AC-015 — the open (zero-coverage) cells ranked by distance to a center
 * point, ascending, capped to top-N. The `prospectLayer` data set.
 */
export function rankOpenCells(
  cells: CoverageCell[],
  center: LatLng,
  topN: number = DEFAULT_PROSPECT_N,
): CoverageCell[] {
  return cells
    .filter((c) => c.coverage === 0)
    .map((c) => {
      const [lat, lng] = cellToLatLng(c.h3);
      return { cell: c, dist: haversineMi({ lat, lng }, center) };
    })
    .sort((a, b) => a.dist - b.dist)
    .slice(0, topN)
    .map((x) => x.cell);
}

/** Inputs for a full viewport coverage recompute. */
export interface ComputeSaturationParams {
  sites: SiteGeo[];
  selectedVertical: string;
  bounds: ViewportBounds;
  zoom: number;
  center: LatLng;
  cellCap?: number;
  padFraction?: number;
  prospectTopN?: number;
}

/**
 * AS-T2 — the full viewport coverage recompute (App/MapShell consumer entry).
 *
 * 1. Resolve the zoom-adaptive resolution (AC-010) + pad the bbox ~20% (D1).
 * 2. Hard cell-count cap (AC-011): estimate candidate cells; if over cap return
 *    an empty capped result (the "Zoom in to compute saturation" path) WITHOUT
 *    tessellating the unbounded bbox.
 * 3. Pre-filter zones to the padded bbox + selected vertical + effective BEFORE
 *    the per-cell loop (AC-013) — cost is O(cells × zonesInViewport).
 * 4. Tessellate (`polygonToCells`) + overlap-weighted per-cell coverage.
 * 5. Split into covered cells (saturationLayer) + ranked open cells
 *    (prospectLayer) + the counts the textual summary reads.
 */
export function computeSaturation(
  params: ComputeSaturationParams,
): SaturationResult {
  const {
    sites,
    selectedVertical,
    bounds,
    zoom,
    center,
    cellCap = DEFAULT_CELL_CAP,
    padFraction = DEFAULT_PAD_FRACTION,
    prospectTopN = DEFAULT_PROSPECT_N,
  } = params;

  const resolution = resolutionForZoom(zoom);
  const padded = padBounds(bounds, padFraction);

  if (estimateCandidateCells(padded, resolution) > cellCap) {
    return {
      cells: [],
      openCells: [],
      coveredCount: 0,
      openCount: 0,
      capped: true,
      resolution,
    };
  }

  // Pre-filter zones to padded bbox + vertical + effective BEFORE the inner loop
  // (AC-013): a zone whose centroid is outside the padded viewport never
  // contributes, even if its nominal radius could reach in (the ~20% pad is the
  // buffer; the approximation is acceptable for a wash per ADR D2).
  const zonesInView = sites.filter(
    (s) =>
      s.vertical === selectedVertical &&
      effectiveRadiusMi(s) > 0 &&
      s.lat != null &&
      s.lng != null &&
      inBounds({ lat: s.lat, lng: s.lng }, padded),
  );

  const h3Cells = polygonToCells(bboxLoop(padded), resolution);
  const allCells: CoverageCell[] = h3Cells.map((h3) => ({
    h3,
    coverage: cellCoverage(h3, zonesInView),
  }));

  const cells = allCells.filter((c) => c.coverage >= 1);
  const openCells = rankOpenCells(allCells, center, prospectTopN);
  const openCount = allCells.length - cells.length;

  return {
    cells,
    openCells,
    coveredCount: cells.length,
    openCount,
    capped: false,
    resolution,
  };
}
