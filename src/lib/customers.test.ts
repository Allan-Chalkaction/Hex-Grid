import { describe, it, expect } from 'vitest';
import { restrictedAreaLabel } from './customers';

/**
 * restrictedAreaLabel unit tests (CG hover card). Pure formatter — no DB /
 * network, runs in the node env. Accepts a structural subset of SiteGeo, so a
 * minimal `{ exclusivity_radius_mi, is_zone_on }` fixture exercises it.
 */
const zone = (exclusivity_radius_mi: number | null, is_zone_on: boolean) => ({
  exclusivity_radius_mi,
  is_zone_on,
});

describe('restrictedAreaLabel', () => {
  it('formats common radii in miles with trailing zeros stripped', () => {
    expect(restrictedAreaLabel(zone(0.5, true))).toBe('0.5 mi');
    expect(restrictedAreaLabel(zone(1, true))).toBe('1 mi');
    expect(restrictedAreaLabel(zone(1.5, true))).toBe('1.5 mi');
    expect(restrictedAreaLabel(zone(3, true))).toBe('3 mi');
  });

  it('collapses float artifacts (2.50 → "2.5", 2.0 → "2")', () => {
    expect(restrictedAreaLabel(zone(2.5, true))).toBe('2.5 mi');
    expect(restrictedAreaLabel(zone(2.0, true))).toBe('2 mi');
  });

  it('reports no restricted area for a null / zero / negative radius', () => {
    expect(restrictedAreaLabel(zone(null, true))).toBe('No restricted area');
    expect(restrictedAreaLabel(zone(0, true))).toBe('No restricted area');
    expect(restrictedAreaLabel(zone(-1, true))).toBe('No restricted area');
  });

  it('reports no restricted area when the zone is off, even with a radius', () => {
    expect(restrictedAreaLabel(zone(2, false))).toBe('No restricted area');
  });
});
