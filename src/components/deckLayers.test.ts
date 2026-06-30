import { describe, it, expect } from 'vitest';
import { buildDeckLayers, type DeckLayerOptions } from './deckLayers';
import type { SiteGeo } from '../lib/customers';

/**
 * Z-order tests (AC-019), updated for the CG multi-select gate. Pure: the
 * builder returns deck.gl layers that construct without a GL context, so the
 * resulting layer-id ORDER is inspectable in node (mirrors saturationLayer.test).
 * The byte-identical-first-paint invariant is asserted by comparing the
 * analysis-overlays-off array to the base composition. `selectedVerticals` now
 * drives pin visibility + saturation (its first element).
 */

const site = (id: string, vertical: string | null): SiteGeo => ({
  id,
  customer_id: `c-${id}`,
  name: id,
  address: null,
  lat: 40,
  lng: -100,
  exclusivity_radius_mi: 5,
  is_zone_on: true,
  vertical,
});

const sites: SiteGeo[] = [site('a', 'gas'), site('b', 'grocery')];

const base: DeckLayerOptions = {
  sites,
  conflictIds: new Set<string>(),
  cells: [],
  openCells: [],
  selectedVerticals: [],
  showHeatmap: false,
  showProspecting: false,
  showZones: true,
  dataVersion: 0,
  resolution: 0,
};

const ids = (o: DeckLayerOptions): string[] =>
  buildDeckLayers(o).map((l) => l.id);

describe('buildDeckLayers z-order (AC-019)', () => {
  it('analysis overlays off → equals the base composition (zones, pins)', () => {
    expect(ids(base)).toEqual(['site-zones', 'site-pins']);
  });

  it('with wash + prospect on (vertical selected) → order wash→prospect→zones→pins', () => {
    expect(
      ids({
        ...base,
        selectedVerticals: ['gas'],
        showHeatmap: true,
        showProspecting: true,
      }),
    ).toEqual(['saturation', 'prospect', 'site-zones', 'site-pins']);
  });

  it('Site zones toggle off removes the zones layer (pins remain)', () => {
    expect(ids({ ...base, showZones: false })).toEqual(['site-pins']);
  });

  it('full stack on → wash→prospect→zones→pins', () => {
    expect(
      ids({
        ...base,
        selectedVerticals: ['gas'],
        showHeatmap: true,
        showProspecting: true,
      }),
    ).toEqual(['saturation', 'prospect', 'site-zones', 'site-pins']);
  });

  it('the multi-select gates BOTH pins and zones to the visible sites', () => {
    const layers = buildDeckLayers({
      ...base,
      selectedVerticals: ['gas'],
    });
    const pins = layers.find((l) => l.id === 'site-pins');
    const zones = layers.find((l) => l.id === 'site-zones');
    // Only the gas site (a) is visible → its pin AND its zone; the grocery site
    // (b) is hidden from both layers.
    expect((pins!.props.data as SiteGeo[]).map((s) => s.id)).toEqual(['a']);
    expect((zones!.props.data as SiteGeo[]).map((s) => s.id)).toEqual(['a']);
  });

  it('empty selection → pins and zones both empty (just the basemap)', () => {
    const layers = buildDeckLayers(base);
    const pins = layers.find((l) => l.id === 'site-pins');
    const zones = layers.find((l) => l.id === 'site-zones');
    expect((pins!.props.data as SiteGeo[])).toEqual([]);
    expect((zones!.props.data as SiteGeo[])).toEqual([]);
  });
});
