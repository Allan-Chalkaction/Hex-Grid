import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { VERTICAL_OPTIONS, verticalLabel } from '../lib/customers';
import {
  VERTICAL_COLORS,
  VERTICAL_NEUTRAL,
  verticalLegendRows,
  rgbCss,
} from '../lib/verticalStyle';

/**
 * RO-T6 tests. The project is node-only (no jsdom/RTL — that's a logged
 * deferral), so the panel is verified by unit-testing its extracted PURE helpers
 * (the vertical-legend row builder + the swatch-color formatter) rather than via
 * an RTL render. The a11y contract (useId labels, native disabled, seeded-empty
 * aria-live, the two fieldsets, the describedby ZIP note) is asserted by
 * inspection + the RO-T7 grep gate. See the COMPLETION_REPORT RTL→pure-logic flag.
 */

describe('verticalLegendRows (RO-T6 / AC-017)', () => {
  const rows = verticalLegendRows();

  it('has one row per VERTICAL_OPTIONS plus a "No vertical" neutral row', () => {
    expect(rows).toHaveLength(VERTICAL_OPTIONS.length + 1);
  });

  it('each vertical row text equals verticalLabel(token) with the palette color', () => {
    VERTICAL_OPTIONS.forEach((o, i) => {
      expect(rows[i].label).toBe(verticalLabel(o.value));
      expect(rows[i].label).toBe(o.label);
      expect(rows[i].color).toEqual(VERTICAL_COLORS[o.value]);
    });
  });

  it('the final row is "No vertical" with the neutral color', () => {
    const last = rows[rows.length - 1];
    expect(last.label).toBe('No vertical');
    expect(last.color).toEqual(VERTICAL_NEUTRAL);
  });

  it('reuses the imported VERTICAL_OPTIONS vocabulary (no re-authoring)', () => {
    // Every non-final row's label is a real VERTICAL_OPTIONS label.
    const optionLabels = new Set(VERTICAL_OPTIONS.map((o) => o.label));
    rows.slice(0, -1).forEach((r) => {
      expect(optionLabels.has(r.label)).toBe(true);
    });
  });
});

describe('rgbCss swatch formatter (RO-T6)', () => {
  it('formats a deck.gl [r,g,b] as a CSS rgb() string', () => {
    expect(rgbCss(VERTICAL_NEUTRAL)).toBe('rgb(107, 114, 128)');
    expect(rgbCss([194, 87, 10])).toBe('rgb(194, 87, 10)');
  });
});

describe('SaturationPanel.tsx source contract (RO-T6 / AC-015/016/017)', () => {
  const src = readFileSync(
    fileURLToPath(new URL('./SaturationPanel.tsx', import.meta.url)),
    'utf8',
  );

  it('renders the "Map layers" heading + the relabeled "Vertical" control', () => {
    expect(src).toContain('<h2>Map layers</h2>');
    expect(src).toContain('>Vertical</label>');
    expect(src).not.toContain('<h2>Saturation</h2>');
  });

  it('imports VERTICAL_OPTIONS (does not re-author the vocabulary)', () => {
    expect(src).toMatch(/import\s*\{[^}]*VERTICAL_OPTIONS[^}]*\}\s*from '\.\.\/lib\/customers'/);
    // No literal re-declaration of the token list in the panel.
    expect(src).not.toMatch(/const\s+VERTICAL_OPTIONS\s*=/);
  });

  it('has the two named fieldsets + the filter checkbox', () => {
    expect(src).toContain('<legend>Reference layers</legend>');
    expect(src).toContain('<legend>Analysis layers</legend>');
    expect(src).toContain("Show only this vertical");
  });

  it('keeps the W4 a11y contract — native disabled (never aria-disabled), seeded-empty aria-live', () => {
    // No aria-disabled JSX attribute (gated controls use native `disabled`).
    expect(src).not.toContain('aria-disabled=');
    expect(src).toContain('disabled={');
    expect(src).toContain('aria-live="polite"');
    // The ZIP toggle ties its disabled helper note via aria-describedby.
    expect(src).toContain('aria-describedby');
  });
});
