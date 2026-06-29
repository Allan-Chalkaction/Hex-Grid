import { describe, it, expect } from 'vitest';
import { saturationLayer, prospectLayer } from './saturationLayer';
import type { CoverageCell } from '../lib/coverage';

/**
 * AS-T3 layer-config tests (AC-017/019). Pure: a deck.gl layer constructs
 * without a GL context, so its props (data filter + color accessors) are
 * inspectable in the node test env, mirroring the AS-T1 siteZonesLayer parity
 * test.
 */

const trigger = { selectedVertical: 'gas', dataVersion: 1, resolution: 7 };

// Distinct real H3 ids (any valid index serves; the builders only read .coverage
// for color + filter on it).
const H = {
  c0: '872a100a5ffffff',
  c1: '872a1008affffff',
  c2: '872a1008effffff',
  c3: '872a10001ffffff',
  c4: '872a10003ffffff',
};

function cell(h3: string, coverage: number): CoverageCell {
  return { h3, coverage };
}

describe('saturationLayer (AS-T3 / AC-017 — discrete Blues ramp + coverage>=1 filter)', () => {
  const cells: CoverageCell[] = [
    cell(H.c0, 0),
    cell(H.c1, 1),
    cell(H.c2, 2),
    cell(H.c3, 3),
    cell(H.c4, 4),
  ];
  const layer = saturationLayer(cells, trigger);
  const data = layer.props.data as CoverageCell[];
  const getFillColor = layer.props.getFillColor as unknown as (
    d: CoverageCell,
  ) => number[];

  it('filters out coverage 0 (open) cells from the wash data', () => {
    expect(data.map((c) => c.coverage).sort()).toEqual([1, 2, 3, 4]);
    expect(data.some((c) => c.coverage === 0)).toBe(false);
  });

  it('returns the exact discrete Blues RGBA per coverage bucket (4 clamps to 3+)', () => {
    expect(getFillColor(cell(H.c1, 1))).toEqual([198, 219, 239, 150]);
    expect(getFillColor(cell(H.c2, 2))).toEqual([107, 174, 214, 170]);
    expect(getFillColor(cell(H.c3, 3))).toEqual([21, 88, 176, 190]);
    expect(getFillColor(cell(H.c4, 4))).toEqual([21, 88, 176, 190]); // 4 → 3+ bucket
  });

  it('is a flat, passive wash (extruded/stroked/pickable all false)', () => {
    expect(layer.props.extruded).toBe(false);
    expect(layer.props.stroked).toBe(false);
    expect(layer.props.pickable).toBe(false);
    expect(layer.props.filled).toBe(true);
  });

  it('keys updateTriggers on [selectedVertical, dataVersion, resolution] (AC-014)', () => {
    expect(layer.props.updateTriggers.getFillColor).toEqual(['gas', 1, 7]);
  });
});

describe('prospectLayer (AS-T3 / AC-019 — green open-area outline)', () => {
  const open: CoverageCell[] = [cell(H.c0, 0), cell(H.c1, 0)];
  const layer = prospectLayer(open, trigger);

  it('renders the faint green fill + crisp green outline RGBA', () => {
    expect(layer.props.getFillColor).toEqual([19, 115, 51, 35]);
    expect(layer.props.getLineColor).toEqual([19, 115, 51, 230]);
    expect(layer.props.getLineWidth).toBe(2);
    expect(layer.props.lineWidthUnits).toBe('pixels');
    expect(layer.props.stroked).toBe(true);
    expect(layer.props.pickable).toBe(false);
    expect(layer.props.extruded).toBe(false);
  });

  it('renders exactly the passed open cells', () => {
    expect((layer.props.data as CoverageCell[]).map((c) => c.h3)).toEqual([H.c0, H.c1]);
  });
});
