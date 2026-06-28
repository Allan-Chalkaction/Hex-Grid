import { describe, it, expect } from 'vitest';
import { effectiveRadiusMi, MILES_TO_METERS } from './coverage';
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
