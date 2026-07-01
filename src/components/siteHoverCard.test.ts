import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * Source-contract tests for the site-pin hover card (CG hover card). The wiring
 * is React/deck.gl/MapLibre render-time behavior that the node-only harness
 * cannot execute (no jsdom), so — mirroring the index.test.ts / MapDrawer.test.ts
 * source-contract idiom — we grep the source for the load-bearing seams:
 * pickable + onHover on the pins layer, the card markup + formatter in MapShell,
 * and the visual-only (pointer-events:none, aria-hidden, above-canvas) card CSS.
 */
const read = (rel: string): string =>
  readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');

const pins = read('./sitePinsLayer.ts');
const shell = read('./MapShell.tsx');
const deck = read('./deckLayers.ts');
const css = read('../index.css');

describe('site hover card — pins layer is pickable + accepts onHover', () => {
  it('keeps pickable:true (pins are hoverable)', () => {
    expect(pins).toMatch(/pickable:\s*true/);
  });

  it('accepts an onHover option and wires it to the layer', () => {
    expect(pins).toMatch(/onHover\?:/);
    expect(pins).toMatch(/\bonHover\b/);
  });

  it('the pure builder forwards a pin-hover callback', () => {
    expect(deck).toMatch(/onSitePinHover/);
  });
});

describe('site hover card — MapShell renders the card', () => {
  it('renders the .site-hover-card with the name + radius label', () => {
    expect(shell).toContain('site-hover-card');
    expect(shell).toContain('restrictedAreaLabel');
  });

  it('lifts hover state from deck picking via a handler', () => {
    expect(shell).toMatch(/handlePinHover/);
    expect(shell).toMatch(/info\.picked/);
  });

  it('the card is aria-hidden (purely visual, never breaks SR/keyboard)', () => {
    expect(shell).toMatch(/aria-hidden="true"/);
  });
});

describe('site hover card — CSS is visual-only and above the canvas', () => {
  const block = css.match(/\.site-hover-card\s*\{[\s\S]*?\}/)?.[0] ?? '';

  it('defines the .site-hover-card block', () => {
    expect(block).not.toBe('');
  });

  it('is pointer-events:none so it never blocks picking', () => {
    expect(block).toMatch(/pointer-events:\s*none/);
  });

  it('is absolutely positioned with a z-index above the map canvas', () => {
    expect(block).toMatch(/position:\s*absolute/);
    expect(block).toMatch(/z-index:\s*\d+/);
  });

  it('uses the white-glass idiom (literal hex, no Tailwind/vars)', () => {
    expect(block).toMatch(/rgba\(255,\s*255,\s*255,\s*0\.96\)/);
    expect(block).toMatch(/#ddd/);
  });
});
