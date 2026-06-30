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
 * MapDrawer tests (CG left-menu redesign). The project is node-only (no
 * jsdom/RTL — a logged deferral), so the drawer is verified by (1) unit-testing
 * its extracted PURE helpers (the vertical-legend row builder + the swatch-color
 * formatter, relocated here from the retired SaturationPanel.test.ts) and (2) a
 * source-contract grep over MapDrawer.tsx + index.css for the a11y + behavior
 * invariants (multi-select chooser, the two fieldsets, native disabled, seeded-
 * empty aria-live, the ZIP describedby note, the 15 s auto-retract, the
 * focusable reopen handle, the hover hot-zone, inert-when-closed, and the
 * prefers-reduced-motion slide). See the COMPLETION_REPORT RTL→pure-logic flag.
 */

describe('verticalLegendRows', () => {
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
});

describe('rgbCss swatch formatter', () => {
  it('formats a deck.gl [r,g,b] as a CSS rgb() string', () => {
    expect(rgbCss(VERTICAL_NEUTRAL)).toBe('rgb(107, 114, 128)');
    expect(rgbCss([194, 87, 10])).toBe('rgb(194, 87, 10)');
  });
});

describe('MapDrawer.tsx source contract', () => {
  const src = readFileSync(
    fileURLToPath(new URL('./MapDrawer.tsx', import.meta.url)),
    'utf8',
  );

  it('is the ONE labeled drawer landmark and relocates the CRUD into it', () => {
    expect(src).toContain('aria-label="Map menu"');
    expect(src).toContain('<CustomerForm');
    expect(src).toContain('<CustomerImport');
    expect(src).toContain('<CustomerList');
  });

  it('roots the drawer in an <aside> complementary landmark (not <main>)', () => {
    // A11Y-002 (WCAG 1.3.1/2.4.1): the drawer is a control panel, not the page's
    // dominant content (the map is) — so it is <aside>, not <main>.
    expect(src).toContain('<aside');
    expect(src).toContain('</aside>');
    expect(src).not.toContain('<main');
  });

  it('gives the auto-retract a user control (A11Y-001 keep-open toggle)', () => {
    // The persistent "Keep panel open" checkbox + state, and the timer honoring
    // it (scheduling is skipped while keepOpen is on).
    expect(src).toContain('Keep panel open');
    expect(src).toContain('keepOpen');
    expect(src).toContain('setKeepOpen');
    expect(src).toContain('if (keepOpen) return');
  });

  it('labels the internal Hide button (A11Y-004)', () => {
    // The collapse button carries an explicit accessible name matching the
    // handle's close label (the literal attr is on the Hide button; the handle
    // uses a dynamic expression).
    expect(src).toContain('aria-label="Close map menu"');
  });

  it('manages focus across Hide/handle (A11Y-003 / A11Y-006)', () => {
    // Hide → focus the now-visible reopen handle; handle-open → focus the first
    // control inside. Both via a ref + requestAnimationFrame.
    expect(src).toContain('handleBtnRef');
    expect(src).toContain('firstControlRef');
    expect(src).toContain('handleBtnRef.current?.focus()');
    expect(src).toContain('firstControlRef.current?.focus()');
  });

  it('does not double-label the CRUD landmark (A11Y-005)', () => {
    // The outer CRUD wrapper no longer carries aria-label="Customers" (the inner
    // CustomerList owns that landmark name).
    expect(src).not.toContain('aria-label="Customers"');
  });

  it('imports VERTICAL_OPTIONS (does not re-author the vocabulary)', () => {
    expect(src).toMatch(
      /import\s*\{[^}]*VERTICAL_OPTIONS[^}]*\}\s*from '\.\.\/lib\/customers'/,
    );
    expect(src).not.toMatch(/const\s+VERTICAL_OPTIONS\s*=/);
  });

  it('renders the vertical chooser as a MULTI-SELECT (checkbox per option)', () => {
    expect(src).toContain('<legend>Verticals</legend>');
    expect(src).toContain('VERTICAL_OPTIONS.map');
    expect(src).toContain('type="checkbox"');
    expect(src).toContain('selectedVerticals.includes(o.value)');
    // No single-select <select> for the vertical gate anymore.
    expect(src).not.toContain('onSelectVertical');
  });

  it('keeps the two named layer fieldsets', () => {
    expect(src).toContain('<legend>Reference layers</legend>');
    expect(src).toContain('<legend>Analysis layers</legend>');
  });

  it('preserves the a11y contract — useId, native disabled, seeded-empty aria-live, ZIP describedby', () => {
    expect(src).toContain('useId');
    expect(src).not.toContain('aria-disabled=');
    expect(src).toContain('disabled={');
    expect(src).toContain('aria-live="polite"');
    expect(src).toContain('aria-describedby');
  });

  it('implements the 15 s auto-retract paused by hover/focus', () => {
    expect(src).toContain('RETRACT_MS = 15000');
    expect(src).toContain('hoveredRef');
    expect(src).toContain('focusWithinRef');
    // The retract fires only when neither hovered nor holding focus.
    expect(src).toContain('!hoveredRef.current && !focusWithinRef.current');
  });

  it('reopens via a focusable, labeled handle AND a hover hot-zone', () => {
    expect(src).toContain("aria-label={open ? 'Close map menu' : 'Open map menu'}");
    expect(src).toContain('aria-expanded={open}');
    expect(src).toContain('map-drawer__hotzone');
    expect(src).toContain('onMouseEnter={openDrawer}');
  });

  it('makes the closed drawer inert (not an off-screen tab trap)', () => {
    expect(src).toContain('inert={!open}');
    expect(src).toContain('map-drawer--closed');
  });
});

describe('index.css drawer contract', () => {
  const css = readFileSync(
    fileURLToPath(new URL('../index.css', import.meta.url)),
    'utf8',
  );

  it('slides via a transform on .map-drawer / .map-drawer--closed', () => {
    expect(css).toContain('.map-drawer--closed');
    expect(css).toContain('translateX(-100%)');
  });

  it('respects prefers-reduced-motion (no slide animation)', () => {
    expect(css).toContain('prefers-reduced-motion: reduce');
  });

  it('has a ~1rem left-edge hover hot-zone', () => {
    expect(css).toContain('.map-drawer__hotzone');
    expect(css).toContain('width: 1rem');
  });

  it('clamps the open handle offset to the drawer max-width (ui-review M1)', () => {
    // The drawer is width:23rem but max-width:92vw, so the open handle offset
    // must clamp the same way or it floats off a narrow viewport.
    expect(css).toContain('left: min(23rem, 92vw)');
  });
});
