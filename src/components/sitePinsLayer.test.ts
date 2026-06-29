import { describe, it, expect } from 'vitest';
import { sitePinsLayer } from './sitePinsLayer';
import { VERTICAL_COLORS, VERTICAL_NEUTRAL } from '../lib/verticalStyle';
import type { SiteGeo } from '../lib/customers';

/**
 * RO-T2 layer-config tests (AC-004/005/006). Pure: a deck.gl ScatterplotLayer
 * constructs without a GL context, so its `data` + `getFillColor` accessor are
 * inspectable in the node env (mirrors saturationLayer.test.ts).
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

describe('sitePinsLayer color-by-vertical (RO-T2 / AC-004)', () => {
  const layer = sitePinsLayer(sites, {
    selectedVertical: null,
    filterToVertical: false,
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

  it('filters out unlocated sites (lat/lng null) in every case', () => {
    const data = layer.props.data as Located[];
    expect(data.map((d) => d.id).sort()).toEqual(['a', 'b', 'c', 'd']);
    expect(data.some((d) => d.lat == null || d.lng == null)).toBe(false);
  });
});

describe('sitePinsLayer opt-in filter (RO-T2 / AC-005)', () => {
  it('(a) filterToVertical on + gas selected → only located gas sites', () => {
    const layer = sitePinsLayer(sites, {
      selectedVertical: 'gas',
      filterToVertical: true,
    });
    const data = layer.props.data as Located[];
    expect(data.map((d) => d.id).sort()).toEqual(['a', 'd']);
    expect(data.every((d) => d.vertical === 'gas')).toBe(true);
  });

  it('(b) filterToVertical off → all located sites (still colored)', () => {
    const layer = sitePinsLayer(sites, {
      selectedVertical: 'gas',
      filterToVertical: false,
    });
    const data = layer.props.data as Located[];
    expect(data.map((d) => d.id).sort()).toEqual(['a', 'b', 'c', 'd']);
  });

  it('(c) filterToVertical on but no vertical selected → all located sites', () => {
    const layer = sitePinsLayer(sites, {
      selectedVertical: null,
      filterToVertical: true,
    });
    const data = layer.props.data as Located[];
    expect(data.map((d) => d.id).sort()).toEqual(['a', 'b', 'c', 'd']);
  });
});

describe('sitePinsLayer stability (RO-T2 / AC-006)', () => {
  it('keeps id "site-pins" and a CONSTANT updateTriggers.getFillColor key', () => {
    const l1 = sitePinsLayer(sites, {
      selectedVertical: 'gas',
      filterToVertical: true,
    });
    const l2 = sitePinsLayer(sites, {
      selectedVertical: null,
      filterToVertical: false,
    });
    expect(l1.props.id).toBe('site-pins');
    expect(l2.props.id).toBe('site-pins');
    expect(l1.props.updateTriggers.getFillColor).toBe('vertical-palette-v1');
    // The key is a constant — identical regardless of selection/filter inputs.
    expect(l1.props.updateTriggers.getFillColor).toBe(
      l2.props.updateTriggers.getFillColor,
    );
  });

  it('defaults to no-filter all-located when options are omitted', () => {
    const layer = sitePinsLayer(sites);
    const data = layer.props.data as Located[];
    expect(data.map((d) => d.id).sort()).toEqual(['a', 'b', 'c', 'd']);
  });
});
