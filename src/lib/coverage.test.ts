import { describe, it, expect } from 'vitest';
import { latLngToCell, cellToLatLng } from 'h3-js';
import {
  effectiveRadiusMi,
  MILES_TO_METERS,
  resolutionForZoom,
  haversineMi,
  coverageForCells,
  rankOpenCells,
  computeSaturation,
  type CoverageCell,
  type ViewportBounds,
} from './coverage';
import { siteZonesLayer } from '../components/siteZonesLayer';
import type { SiteGeo } from './customers';

/**
 * AS-T1 unit + parity tests for the shared effective-radius rule.
 *
 * Pure, no DB. (coverage.ts has no supabase import; siteZonesLayer imports
 * deck.gl which constructs a layer object without a GL context — fine in node.)
 */

function site(partial: Partial<SiteGeo> = {}): SiteGeo {
  return {
    id: 'site-1',
    customer_id: 'cust-1',
    name: 'Acme #1',
    address: '1 Main St',
    lat: 40.0,
    lng: -74.0,
    exclusivity_radius_mi: 1,
    is_zone_on: true,
    vertical: 'gas',
    ...partial,
  };
}

describe('effectiveRadiusMi (AS-T1 / AC-001 — the shared W3 effective-zone rule)', () => {
  it('returns 0 when the zone is OFF, regardless of a positive radius', () => {
    expect(effectiveRadiusMi(site({ is_zone_on: false, exclusivity_radius_mi: 5 }))).toBe(0);
  });

  it('returns 0 when the radius is NULL even with the zone ON', () => {
    expect(effectiveRadiusMi(site({ is_zone_on: true, exclusivity_radius_mi: null }))).toBe(0);
  });

  it('returns 0 for a zero radius with the zone ON', () => {
    expect(effectiveRadiusMi(site({ is_zone_on: true, exclusivity_radius_mi: 0 }))).toBe(0);
  });

  it('returns the radius for a positive ON zone', () => {
    expect(effectiveRadiusMi(site({ is_zone_on: true, exclusivity_radius_mi: 2.5 }))).toBe(2.5);
  });

  it('is owner-independent — customer_id does not change the result (AC-008 root)', () => {
    const a = effectiveRadiusMi(site({ customer_id: 'A', exclusivity_radius_mi: 3 }));
    const b = effectiveRadiusMi(site({ customer_id: 'B', exclusivity_radius_mi: 3 }));
    expect(a).toBe(b);
  });
});

describe('effectiveRadiusMi ↔ siteZonesLayer parity (AS-T1 / AC-002, AC-003 — drift kill)', () => {
  // A representative mix: on+positive (draws), off (no draw), null radius (no
  // draw), zero radius (no draw), and unlocated (filtered by lat/lng).
  const sites: SiteGeo[] = [
    site({ id: 'draws-1', is_zone_on: true, exclusivity_radius_mi: 1.5 }),
    site({ id: 'draws-2', is_zone_on: true, exclusivity_radius_mi: 0.5, lat: 41, lng: -73 }),
    site({ id: 'off', is_zone_on: false, exclusivity_radius_mi: 4 }),
    site({ id: 'null-r', is_zone_on: true, exclusivity_radius_mi: null }),
    site({ id: 'zero-r', is_zone_on: true, exclusivity_radius_mi: 0 }),
    site({ id: 'unlocated', is_zone_on: true, exclusivity_radius_mi: 2, lat: null, lng: null }),
  ];

  const layer = siteZonesLayer(sites, new Set<string>());
  const drawn = layer.props.data as SiteGeo[];
  const drawnIds = new Set(drawn.map((s) => s.id));

  it('a site is in the rendered data set IFF effectiveRadiusMi(s) > 0 (and it is located)', () => {
    for (const s of sites) {
      const shouldDraw = effectiveRadiusMi(s) > 0 && s.lat != null && s.lng != null;
      expect(drawnIds.has(s.id)).toBe(shouldDraw);
    }
    // Concretely: only the two positive on-zone located sites draw.
    expect([...drawnIds].sort()).toEqual(['draws-1', 'draws-2']);
  });

  it('the rendered meters radius equals effectiveRadiusMi(s) × MILES_TO_METERS (1609.344)', () => {
    const getRadius = layer.props.getRadius as (d: SiteGeo) => number;
    for (const s of drawn) {
      expect(getRadius(s)).toBeCloseTo(effectiveRadiusMi(s) * MILES_TO_METERS, 6);
    }
    // Pin the constant so a one-sided edit to either side breaks the test.
    expect(MILES_TO_METERS).toBe(1609.344);
    const draws1 = drawn.find((s) => s.id === 'draws-1')!;
    expect(getRadius(draws1)).toBeCloseTo(1.5 * 1609.344, 6);
  });
});

// ---------------------------------------------------------------------------
// AS-T2 — coverage compute core (overlap-weighted, zoom→res, cap, prospect).
// ---------------------------------------------------------------------------

const RES = 7;
const MI_PER_DEG_LAT = 3958.7613 * (Math.PI / 180); // ~69.094 mi per deg latitude

/** A cell + its centroid for a chosen anchor coordinate (deterministic). */
function cellAt(lat: number, lng: number, res = RES): { h3: string; lat: number; lng: number } {
  const h3 = latLngToCell(lat, lng, res);
  const [clat, clng] = cellToLatLng(h3);
  return { h3, lat: clat, lng: clng };
}

/** A site positioned exactly at a centroid (distance 0 ⇒ always covered for r>0). */
function zoneAt(lat: number, lng: number, partial: Partial<SiteGeo> = {}): SiteGeo {
  return site({ lat, lng, exclusivity_radius_mi: 1, is_zone_on: true, vertical: 'gas', ...partial });
}

describe('resolutionForZoom (AS-T2 / AC-010 — zoom-adaptive H3 resolution)', () => {
  it('maps the ADR D4 table including bracket edges', () => {
    expect(resolutionForZoom(4)).toBe(4);
    expect(resolutionForZoom(5)).toBe(6);
    expect(resolutionForZoom(7)).toBe(6);
    expect(resolutionForZoom(8)).toBe(7);
    expect(resolutionForZoom(10)).toBe(7);
    expect(resolutionForZoom(11)).toBe(8);
  });

  it('clamps out-of-range and non-finite zooms', () => {
    expect(resolutionForZoom(0)).toBe(4);
    expect(resolutionForZoom(22)).toBe(8);
    expect(resolutionForZoom(-3)).toBe(4);
    expect(resolutionForZoom(NaN)).toBe(4);
  });
});

describe('haversineMi (AS-T2 / AC-009 metric)', () => {
  it('is ~0 for identical points', () => {
    expect(haversineMi({ lat: 40, lng: -74 }, { lat: 40, lng: -74 })).toBeCloseTo(0, 6);
  });
  it('measures a known north-south offset in miles', () => {
    const a = { lat: 40, lng: -74 };
    const b = { lat: 40 + 1 / MI_PER_DEG_LAT, lng: -74 }; // 1 mi north
    expect(haversineMi(a, b)).toBeCloseTo(1, 3);
  });
});

describe('coverageForCells overlap-weighted (AS-T2 / AC-004..009)', () => {
  const anchor = cellAt(40.0, -74.0);

  it('AC-004 — coverage is a COUNT of covering same-vertical zones (2, then 3)', () => {
    const far = cellAt(41.5, -72.0); // a clearly different cell far away
    const twoOfThree = [
      zoneAt(anchor.lat, anchor.lng),
      zoneAt(anchor.lat, anchor.lng),
      zoneAt(far.lat, far.lng), // covers `far`, not `anchor`
    ];
    expect(coverageForCells([anchor.h3], twoOfThree, 'gas')[0].coverage).toBe(2);

    const allThree = [
      zoneAt(anchor.lat, anchor.lng),
      zoneAt(anchor.lat, anchor.lng),
      zoneAt(anchor.lat, anchor.lng),
    ];
    expect(coverageForCells([anchor.h3], allThree, 'gas')[0].coverage).toBe(3);
  });

  it('AC-005 — a cell outside every zone is coverage 0 (open)', () => {
    const farZone = zoneAt(10.0, 10.0); // nowhere near the anchor
    expect(coverageForCells([anchor.h3], [farZone], 'gas')[0].coverage).toBe(0);
  });

  it('AC-006 — other-vertical zones never contribute', () => {
    const grocery = [zoneAt(anchor.lat, anchor.lng, { vertical: 'grocery' })];
    expect(coverageForCells([anchor.h3], grocery, 'gas')[0].coverage).toBe(0);
    expect(coverageForCells([anchor.h3], grocery, 'grocery')[0].coverage).toBe(1);
  });

  it('AC-007 — off / null-radius / zero-radius zones never contribute', () => {
    const off = zoneAt(anchor.lat, anchor.lng, { is_zone_on: false, exclusivity_radius_mi: 5 });
    const nullR = zoneAt(anchor.lat, anchor.lng, { exclusivity_radius_mi: null });
    const zeroR = zoneAt(anchor.lat, anchor.lng, { exclusivity_radius_mi: 0 });
    expect(coverageForCells([anchor.h3], [off, nullR, zeroR], 'gas')[0].coverage).toBe(0);
  });

  it('AC-008 — coverage is owner-independent (customer_id; self_conflict absent from SiteGeo)', () => {
    const sameOwner = [
      zoneAt(anchor.lat, anchor.lng, { customer_id: 'A' }),
      zoneAt(anchor.lat, anchor.lng, { customer_id: 'A' }),
    ];
    const diffOwner = [
      zoneAt(anchor.lat, anchor.lng, { customer_id: 'A' }),
      zoneAt(anchor.lat, anchor.lng, { customer_id: 'B' }),
    ];
    const cov = (z: SiteGeo[]): number => coverageForCells([anchor.h3], z, 'gas')[0].coverage;
    expect(cov(sameOwner)).toBe(cov(diffOwner));
    expect(cov(diffOwner)).toBe(2);
    // `self_conflict` is not part of the SiteGeo read shape — the compute can
    // not even see it, so it is structurally ignored (AC-008).
  });

  it('AC-009 — centroid-in-circle boundary: 0.4 mi counted, 0.6 mi not (r=0.5)', () => {
    const near = zoneAt(anchor.lat + 0.4 / MI_PER_DEG_LAT, anchor.lng, { exclusivity_radius_mi: 0.5 });
    const farJust = zoneAt(anchor.lat + 0.6 / MI_PER_DEG_LAT, anchor.lng, { exclusivity_radius_mi: 0.5 });
    // sanity: the constructed distances straddle the 0.5 mi radius
    expect(haversineMi({ lat: anchor.lat, lng: anchor.lng }, { lat: near.lat as number, lng: near.lng as number })).toBeLessThan(0.5);
    expect(haversineMi({ lat: anchor.lat, lng: anchor.lng }, { lat: farJust.lat as number, lng: farJust.lng as number })).toBeGreaterThan(0.5);
    expect(coverageForCells([anchor.h3], [near], 'gas')[0].coverage).toBe(1);
    expect(coverageForCells([anchor.h3], [farJust], 'gas')[0].coverage).toBe(0);
  });
});

describe('computeSaturation cap + bbox pre-filter (AS-T2 / AC-011, AC-013)', () => {
  const metro: ViewportBounds = { west: -74.1, south: 40.7, east: -73.9, north: 40.9 };
  const conus: ViewportBounds = { west: -125, south: 24, east: -66, north: 50 };
  const center = { lat: 40.8, lng: -74.0 };

  it('AC-011 — a CONUS bbox at low-zoom resolution trips the cap; a metro bbox passes', () => {
    const capped = computeSaturation({ sites: [], selectedVertical: 'gas', bounds: conus, zoom: 4, center });
    expect(capped.capped).toBe(true);
    expect(capped.cells).toHaveLength(0);

    const ok = computeSaturation({ sites: [], selectedVertical: 'gas', bounds: metro, zoom: 9, center });
    expect(ok.capped).toBe(false);
  });

  it('AC-013 — a zone far OUTSIDE the padded bbox never contributes, even with a huge radius', () => {
    const farHuge = zoneAt(0, 0, { exclusivity_radius_mi: 5000 }); // off Africa; nominally covers everything
    const res = computeSaturation({ sites: [farHuge], selectedVertical: 'gas', bounds: metro, zoom: 9, center });
    expect(res.capped).toBe(false);
    expect(res.coveredCount).toBe(0);

    // An IN-bbox zone of the same vertical DOES produce covered cells.
    const inside = zoneAt(40.8, -74.0, { exclusivity_radius_mi: 3 });
    const res2 = computeSaturation({ sites: [inside], selectedVertical: 'gas', bounds: metro, zoom: 9, center });
    expect(res2.coveredCount).toBeGreaterThan(0);
    expect(res2.cells.every((c) => c.coverage >= 1)).toBe(true);
  });
});

describe('rankOpenCells (AS-T2 / AC-015 — nearest-first, capped to N)', () => {
  it('returns coverage===0 cells nearest-first, length <= N', () => {
    const center = { lat: 40.0, lng: -74.0 };
    // Three open cells at increasing northward distance from center.
    const near: CoverageCell = { h3: latLngToCell(40.05, -74.0, RES), coverage: 0 };
    const mid: CoverageCell = { h3: latLngToCell(40.3, -74.0, RES), coverage: 0 };
    const far: CoverageCell = { h3: latLngToCell(40.8, -74.0, RES), coverage: 0 };
    const covered: CoverageCell = { h3: latLngToCell(40.06, -74.0, RES), coverage: 2 };
    const ranked = rankOpenCells([far, covered, mid, near], center, 2);
    expect(ranked).toHaveLength(2); // capped to N=2
    expect(ranked.map((c) => c.h3)).toEqual([near.h3, mid.h3]); // nearest first, covered excluded
  });
});
