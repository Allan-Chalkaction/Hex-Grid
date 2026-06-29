import { VERTICAL_OPTIONS } from './customers';

/**
 * The stable per-vertical categorical color palette (RO-T1 — AC-001/002/003).
 *
 * `VERTICAL_COLORS` keys on the 8 controlled `VERTICAL_OPTIONS` tokens (imported,
 * NEVER re-authored) → a stable `[r,g,b]` deck.gl fill, with `VERTICAL_NEUTRAL`
 * the fallback for a `null`/unknown vertical. It is a MODULE-LEVEL const, so the
 * color for a given token is stable by construction across renders/sessions.
 *
 * The palette is CATEGORICAL (distinct hues), deliberately chosen to avoid the
 * three reserved semantic color families so a site pin's vertical can never read
 * as a conflict, a saturation bucket, or a prospect cell (ui-spec §4):
 *   - conflict-red       [176, 0, 32]   (#b00020)
 *   - saturation Blues   [198,219,239] / [107,174,214] / [21,88,176]
 *   - prospect-green     [19, 115, 51]  (#137333)
 *
 * Every fill clears the conservative 3:1 graphical-object bar on pure white;
 * color-by-vertical is orientation/reinforcement — the panel legend (real text
 * per row) + the opt-in single-vertical filter are the authoritative carriers.
 */
export type RGB = [number, number, number];

/** Fallback for `null` / unknown vertical — neutral grey (#6b7280). */
export const VERTICAL_NEUTRAL: RGB = [107, 114, 128];

/** Stable categorical fill per `VERTICAL_OPTIONS` token (ui-spec §4 table). */
export const VERTICAL_COLORS: Readonly<Record<string, RGB>> = {
  gas: [194, 87, 10], // #c2570a — orange
  grocery: [162, 28, 175], // #a21caf — magenta
  pharmacy: [15, 118, 110], // #0f766e — teal
  qsr: [190, 24, 93], // #be185d — rose
  restaurant: [67, 56, 202], // #4338ca — indigo
  fitness: [77, 124, 15], // #4d7c0f — olive-lime
  automotive: [146, 64, 14], // #92400e — brown
  banking: [71, 85, 105], // #475569 — slate
  hotel: [126, 34, 206], // #7e22ce — violet
};

/**
 * Resolve a (possibly null/unknown) vertical token to its stable fill, never
 * `undefined` — the exact accessor `sitePinsLayer.getFillColor` uses (AC-003).
 */
export function verticalColor(vertical: string | null | undefined): RGB {
  return VERTICAL_COLORS[vertical ?? ''] ?? VERTICAL_NEUTRAL;
}

/** One vertical-color-legend row (swatch color + the SR-carrier text). */
export interface VerticalLegendRow {
  label: string;
  color: RGB;
}

/**
 * The vertical color legend rows (RO-T6 — AC-017): one row per `VERTICAL_OPTIONS`
 * (label = the human option label = `verticalLabel(token)`) plus a final "No
 * vertical" neutral row. `VERTICAL_OPTIONS` is imported, never re-authored. Pure
 * (node-testable). Lives next to the palette it reads (keeps the panel a
 * components-only module — react-refresh).
 */
export function verticalLegendRows(): VerticalLegendRow[] {
  return [
    ...VERTICAL_OPTIONS.map((o) => ({
      label: o.label,
      color: VERTICAL_COLORS[o.value] ?? VERTICAL_NEUTRAL,
    })),
    { label: 'No vertical', color: VERTICAL_NEUTRAL },
  ];
}

/** A deck.gl `[r,g,b]` fill → a CSS `rgb()` string for a legend swatch bg. */
export function rgbCss([r, g, b]: RGB): string {
  return `rgb(${r}, ${g}, ${b})`;
}

// Re-export so the panel legend reads the vocabulary from one place — consumers
// import VERTICAL_OPTIONS via customers.ts (or this module), never redeclaring it.
export { VERTICAL_OPTIONS };
