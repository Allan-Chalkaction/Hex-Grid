import { describe, it, expect, vi, afterEach } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type maplibregl from 'maplibre-gl';
import {
  zctaConfigured,
  zctaTilesUrl,
  zctaSourceLabel,
  resolveZcta5,
  addZctaSource,
  setZctaVisible,
} from './zctaSource';

/**
 * RO-T4 tests (AC-012/013/014). `import.meta.env` is mocked via vi.stubEnv; the
 * MapLibre map is a method-mock (the style spec objects are inspectable without a
 * GL/DOM context — mirrors the layer-config test posture). Live tile rendering +
 * the click popup are operator-dependent and verified post-provisioning.
 */

interface MockMap {
  isStyleLoaded: ReturnType<typeof vi.fn>;
  getSource: ReturnType<typeof vi.fn>;
  getLayer: ReturnType<typeof vi.fn>;
  addSource: ReturnType<typeof vi.fn>;
  addLayer: ReturnType<typeof vi.fn>;
  on: ReturnType<typeof vi.fn>;
  setLayoutProperty: ReturnType<typeof vi.fn>;
  queryRenderedFeatures: ReturnType<typeof vi.fn>;
}

function mockMap(over: Partial<MockMap> = {}): MockMap {
  return {
    isStyleLoaded: vi.fn(() => true),
    getSource: vi.fn(() => undefined),
    getLayer: vi.fn(() => ({})),
    addSource: vi.fn(),
    addLayer: vi.fn(),
    on: vi.fn(),
    setLayoutProperty: vi.fn(),
    queryRenderedFeatures: vi.fn(() => []),
    ...over,
  };
}

const asMap = (m: MockMap): maplibregl.Map => m as unknown as maplibregl.Map;

afterEach(() => {
  vi.unstubAllEnvs();
});

describe('zctaConfigured / zctaTilesUrl (RO-T4 / AC-012/013)', () => {
  it('is false + undefined when VITE_ZCTA_TILES_URL is unset', () => {
    expect(zctaConfigured()).toBe(false);
    expect(zctaTilesUrl()).toBeUndefined();
  });

  it('is true + the URL when set', () => {
    vi.stubEnv('VITE_ZCTA_TILES_URL', 'https://tiles.example.com/zcta.json');
    expect(zctaConfigured()).toBe(true);
    expect(zctaTilesUrl()).toBe('https://tiles.example.com/zcta.json');
  });
});

describe('zctaSourceLabel (EH-T3 / AC-009)', () => {
  it('returns the honest default "ZCTA approximation" when unset', () => {
    expect(zctaSourceLabel()).toBe('ZCTA approximation');
  });

  it('returns VITE_ZCTA_SOURCE_LABEL when set (e.g. a true-USPS tileset)', () => {
    vi.stubEnv('VITE_ZCTA_SOURCE_LABEL', 'USPS ZIP');
    expect(zctaSourceLabel()).toBe('USPS ZIP');
  });
});

describe('SaturationPanel toggle consumes zctaSourceLabel (EH-T3 / AC-010)', () => {
  const src = readFileSync(
    fileURLToPath(new URL('./SaturationPanel.tsx', import.meta.url)),
    'utf8',
  );

  it('the ZIP toggle label calls the helper (not a hardcoded source string)', () => {
    expect(src).toContain('zctaSourceLabel()');
    expect(src).not.toContain('ZIP / ZCTA boundaries');
  });

  it('preserves the htmlFor / aria-describedby wiring (a11y unchanged)', () => {
    expect(src).toContain('htmlFor={zctaId}');
    expect(src).toContain('aria-describedby');
  });
});

describe('addZctaSource unconfigured = NO-OP (RO-T4 / AC-012)', () => {
  it('adds no source / no layer / binds nothing when unset', () => {
    const map = mockMap();
    addZctaSource(asMap(map));
    expect(map.addSource).not.toHaveBeenCalled();
    expect(map.addLayer).not.toHaveBeenCalled();
    expect(map.on).not.toHaveBeenCalled();
  });
});

describe('addZctaSource configured (RO-T4 / AC-013)', () => {
  it('adds the source once + both layers initially hidden with the spec paint', () => {
    vi.stubEnv('VITE_ZCTA_TILES_URL', 'https://tiles.example.com/zcta.json');
    const map = mockMap();
    addZctaSource(asMap(map));

    expect(map.addSource).toHaveBeenCalledTimes(1);
    const [srcId, srcSpec] = map.addSource.mock.calls[0];
    expect(srcId).toBe('zcta-src');
    expect(srcSpec).toMatchObject({
      type: 'vector',
      url: 'https://tiles.example.com/zcta.json',
    });

    expect(map.addLayer).toHaveBeenCalledTimes(2);
    const fill = map.addLayer.mock.calls[0][0];
    const line = map.addLayer.mock.calls[1][0];

    expect(fill.id).toBe('zcta-fill');
    expect(fill.type).toBe('fill');
    expect(fill.layout.visibility).toBe('none');
    expect(fill.paint['fill-color']).toBe('#6b7280');
    expect(fill.paint['fill-opacity']).toBeCloseTo(0.04);

    expect(line.id).toBe('zcta-line');
    expect(line.type).toBe('line');
    expect(line.layout.visibility).toBe('none');
    expect(line.paint['line-color']).toBe('#6b7280');
    // zoom-interpolated opacity + width.
    expect(line.paint['line-opacity'][0]).toBe('interpolate');
    expect(line.paint['line-width'][0]).toBe('interpolate');

    // fill BEFORE line so the line strokes read over the fill.
    expect(map.addLayer.mock.invocationCallOrder[0]).toBeLessThan(
      map.addLayer.mock.invocationCallOrder[1],
    );
  });

  it('is idempotent — no double-add when the source already exists', () => {
    vi.stubEnv('VITE_ZCTA_TILES_URL', 'https://tiles.example.com/zcta.json');
    const map = mockMap({ getSource: vi.fn(() => ({})) });
    addZctaSource(asMap(map));
    expect(map.addSource).not.toHaveBeenCalled();
  });

  it('is a no-op when the style is not yet loaded', () => {
    vi.stubEnv('VITE_ZCTA_TILES_URL', 'https://tiles.example.com/zcta.json');
    const map = mockMap({ isStyleLoaded: vi.fn(() => false) });
    addZctaSource(asMap(map));
    expect(map.addSource).not.toHaveBeenCalled();
  });
});

describe('setZctaVisible (RO-T4 / AC-013)', () => {
  it('flips both layers to visible / none', () => {
    const map = mockMap();
    setZctaVisible(asMap(map), true);
    expect(map.setLayoutProperty).toHaveBeenCalledWith(
      'zcta-fill',
      'visibility',
      'visible',
    );
    expect(map.setLayoutProperty).toHaveBeenCalledWith(
      'zcta-line',
      'visibility',
      'visible',
    );

    map.setLayoutProperty.mockClear();
    setZctaVisible(asMap(map), false);
    expect(map.setLayoutProperty).toHaveBeenCalledWith(
      'zcta-fill',
      'visibility',
      'none',
    );
    expect(map.setLayoutProperty).toHaveBeenCalledWith(
      'zcta-line',
      'visibility',
      'none',
    );
  });

  it('is a no-op when the layers are absent (unconfigured/unmounted)', () => {
    const map = mockMap({ getLayer: vi.fn(() => undefined) });
    setZctaVisible(asMap(map), true);
    expect(map.setLayoutProperty).not.toHaveBeenCalled();
  });
});

describe('resolveZcta5 id resolver (RO-T4 / AC-014)', () => {
  it('reads the pinned key first', () => {
    expect(resolveZcta5({ ZCTA5CE20: '94203', GEOID20: '06067' })).toBe('94203');
    expect(resolveZcta5({ GEOID20: '90001' })).toBe('90001');
  });

  it('falls back to the first 5-digit property when no pinned key matches', () => {
    expect(resolveZcta5({ FOO: 'bar', ZIP: '10001' })).toBe('10001');
    expect(resolveZcta5({ code: 60614 })).toBe('60614');
  });

  it('returns null when no 5-digit property exists (silent no-op)', () => {
    expect(resolveZcta5({ name: 'Somewhere', n: 42 })).toBeNull();
    expect(resolveZcta5(null)).toBeNull();
    expect(resolveZcta5(undefined)).toBeNull();
  });
});
