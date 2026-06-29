import { describe, it, expect } from 'vitest';
import {
  VERTICAL_COLORS,
  VERTICAL_NEUTRAL,
  verticalColor,
} from './verticalStyle';
import { VERTICAL_OPTIONS } from './customers';

/**
 * RO-T1 palette tests (AC-001/002/003). Pure logic — no GL, no render.
 */

/** The reserved semantic triples no VERTICAL_COLORS entry may collide with. */
const RESERVED: ReadonlyArray<[number, number, number]> = [
  [176, 0, 32], // conflict-red #b00020
  [198, 219, 239], // saturation 1 zone #c6dbef
  [107, 174, 214], // saturation 2 zones #6baed6
  [21, 88, 176], // saturation 3+ / old pin / zone stroke #1558b0
  [19, 115, 51], // prospect-green #137333
];

describe('VERTICAL_COLORS / VERTICAL_NEUTRAL (RO-T1 / AC-001)', () => {
  it('has a color for every VERTICAL_OPTIONS token, each a finite [r,g,b] triple', () => {
    for (const { value } of VERTICAL_OPTIONS) {
      const c = VERTICAL_COLORS[value];
      expect(c, `missing color for ${value}`).toBeDefined();
      expect(c).toHaveLength(3);
      for (const ch of c) {
        expect(Number.isInteger(ch)).toBe(true);
        expect(ch).toBeGreaterThanOrEqual(0);
        expect(ch).toBeLessThanOrEqual(255);
      }
    }
  });

  it('keys ONLY on the 8 controlled tokens (no stray entries / no re-authored vocabulary)', () => {
    const tokens = VERTICAL_OPTIONS.map((o) => o.value).sort();
    expect(Object.keys(VERTICAL_COLORS).sort()).toEqual(tokens);
  });

  it('the neutral fallback is exactly [107,114,128]', () => {
    expect(VERTICAL_NEUTRAL).toEqual([107, 114, 128]);
  });
});

describe('palette ↔ reserved-semantics separation (RO-T1 / AC-002)', () => {
  it('no palette entry (nor the neutral) collides with a reserved triple', () => {
    const all = [...Object.values(VERTICAL_COLORS), VERTICAL_NEUTRAL];
    for (const c of all) {
      for (const r of RESERVED) {
        expect(c).not.toEqual(r);
      }
    }
  });

  it('every palette entry is distinct from every other (categorical)', () => {
    const seen = new Set<string>();
    for (const c of Object.values(VERTICAL_COLORS)) {
      const k = c.join(',');
      expect(seen.has(k), `duplicate palette color ${k}`).toBe(false);
      seen.add(k);
    }
  });
});

describe('verticalColor() resolver (RO-T1 / AC-003)', () => {
  it('returns the token color for each listed token', () => {
    for (const { value } of VERTICAL_OPTIONS) {
      expect(verticalColor(value)).toEqual(VERTICAL_COLORS[value]);
    }
  });

  it('returns the neutral (never undefined) for "", null, undefined, and unlisted', () => {
    expect(verticalColor('')).toEqual(VERTICAL_NEUTRAL);
    expect(verticalColor(null)).toEqual(VERTICAL_NEUTRAL);
    expect(verticalColor(undefined)).toEqual(VERTICAL_NEUTRAL);
    expect(verticalColor('not-a-real-vertical')).toEqual(VERTICAL_NEUTRAL);
  });

  it('mirrors the inline accessor form `VERTICAL_COLORS[v ?? ""] ?? NEUTRAL`', () => {
    const accessor = (v: string | null) =>
      VERTICAL_COLORS[v ?? ''] ?? VERTICAL_NEUTRAL;
    expect(accessor('gas')).toEqual(verticalColor('gas'));
    expect(accessor(null)).toEqual(verticalColor(null));
  });
});
