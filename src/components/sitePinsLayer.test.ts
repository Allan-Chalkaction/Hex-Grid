import { describe, it, expect } from 'vitest';
import { sitePinsLayer } from './sitePinsLayer';
import { VERTICAL_COLORS, VERTICAL_NEUTRAL } from '../lib/verticalStyle';
import type { SiteGeo } from '../lib/customers';

/**
 * sitePinsLayer layer-config tests (CG left-menu redesign — multi-select gate).
 * Pure: a deck.gl ScatterplotLayer constructs without a GL context, so its
 * `data` + `getFillColor` accessor are inspectable in the node env (mirrors
 * saturationLayer.test.ts). The pin set is now gated by `selectedVerticals`
 * (default [] => no pins); coloring-by-vertical of the visible set is unchanged.
 */

function site(
  id: string,
  vertical: string | null,
  lat: number | null,
  lng: number | null,
): SiteGeo {
  return {
    id,
    customer_id: `c-${id}`,
    name: `Site ${id}`,
    address: '123 Main St',
    lat,
    lng,
    exclusivity_radius_mi: null,
    is_zone_on: false,
    vertical,
    customer_name: `Brand ${id}`,
  };
}

// Mixed verticals incl. a null + two unlocated (one located gas, one null-located).
const sites: SiteGeo[] = [
  site('a', 'gas', 40.0, -100.0),
  site('b', 'grocery', 41.0, -101.0),
  site('c', null, 42.0, -102.0),
  site('d', 'gas', 43.0, -103.0),
  site('e', 'pharmacy', null, -104.0), // unlocated → never rendered
  site('f', 'gas', 44.0, null), // unlocated → never rendered
];

type Located = SiteGeo & { lat: number; lng: number };

describe('sitePinsLayer color-by-vertical', () => {
  // The fill accessor is independent of the visible-data set; a broad selection
  // gives a non-empty data set for the located-filter assertion.
  const layer = sitePinsLayer(sites, {
    selectedVerticals: ['gas', 'grocery', 'pharmacy'],
  });
  const getFillColor = layer.props.getFillColor as unknown as (
    d: Located,
  ) => number[];

  it('colors each located pin by its vertical via the palette', () => {
    expect(getFillColor(site('a', 'gas', 40, -100) as Located)).toEqual(
      VERTICAL_COLORS.gas,
    );
    expect(getFillColor(site('b', 'grocery', 41, -101) as Located)).toEqual(
      VERTICAL_COLORS.grocery,
    );
  });

  it('colors a null/unknown vertical with the neutral (never undefined)', () => {
    expect(getFillColor(site('c', null, 42, -102) as Located)).toEqual(
      VERTICAL_NEUTRAL,
    );
    expect(
      getFillColor(site('z', 'not-real', 1, 1) as Located),
    ).toEqual(VERTICAL_NEUTRAL);
  });

  it('the fill is opaque (a 3-tuple, no alpha)', () => {
    expect(getFillColor(site('a', 'gas', 40, -100) as Located)).toHaveLength(3);
  });

  it('renders only located sites whose vertical is selected', () => {
    // c is null-vertical (never selectable); e/f are unlocated.
    const data = layer.props.data as Located[];
    expect(data.map((d) => d.id).sort()).toEqual(['a', 'b', 'd']);
    expect(data.some((d) => d.lat == null || d.lng == null)).toBe(false);
  });
});

describe('sitePinsLayer multi-select gate', () => {
  it('(a) empty selection → NO pins (default load shows just the basemap)', () => {
    const layer = sitePinsLayer(sites, { selectedVerticals: [] });
    expect((layer.props.data as Located[])).toEqual([]);
  });

  it('(b) one vertical selected → only that vertical\'s located sites', () => {
    const layer = sitePinsLayer(sites, { selectedVerticals: ['gas'] });
    const data = layer.props.data as Located[];
    expect(data.map((d) => d.id).sort()).toEqual(['a', 'd']);
    expect(data.every((d) => d.vertical === 'gas')).toBe(true);
  });

  it('(c) multiple verticals selected → the union of their located sites', () => {
    const layer = sitePinsLayer(sites, {
      selectedVerticals: ['gas', 'grocery'],
    });
    const data = layer.props.data as Located[];
    expect(data.map((d) => d.id).sort()).toEqual(['a', 'b', 'd']);
  });

  it('(d) a null-vertical site never renders even when others are selected', () => {
    const layer = sitePinsLayer(sites, { selectedVerticals: ['gas'] });
    const data = layer.props.data as Located[];
    expect(data.some((d) => d.id === 'c')).toBe(false);
  });
});

describe('sitePinsLayer stability', () => {
  it('keeps id "site-pins" and a CONSTANT updateTriggers.getFillColor key', () => {
    const l1 = sitePinsLayer(sites, { selectedVerticals: ['gas'] });
    const l2 = sitePinsLayer(sites, { selectedVerticals: [] });
    expect(l1.props.id).toBe('site-pins');
    expect(l2.props.id).toBe('site-pins');
    expect(l1.props.updateTriggers.getFillColor).toBe('vertical-palette-v1');
    // The key is a constant — identical regardless of the selection input.
    expect(l1.props.updateTriggers.getFillColor).toBe(
      l2.props.updateTriggers.getFillColor,
    );
  });

  it('defaults to the empty (no-pins) set when options are omitted', () => {
    const layer = sitePinsLayer(sites);
    expect((layer.props.data as Located[])).toEqual([]);
  });
});
