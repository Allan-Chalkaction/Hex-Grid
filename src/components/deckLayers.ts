import { sitePinsLayer } from './sitePinsLayer';
import { siteZonesLayer } from './siteZonesLayer';
import { saturationLayer, prospectLayer } from './saturationLayer';
import {
  capitalsLayer,
  metrosLayer,
  shouldShowMetros,
} from './referenceLabelsLayer';
import capitals from '../data/capitals.json';
import metros from '../data/metros.json';
import type { SiteGeo } from '../lib/customers';
import type { CoverageCell } from '../lib/coverage';

/**
 * The pure deck.gl overlay layer-array builder (RO-T5 — AC-019), extracted from
 * MapShell so the load-bearing z-order is unit-testable without a GL/maplibre/
 * React context (mirrors the saturationLayer.test posture). MapShell's reactive
 * effect is the sole caller.
 */
export interface DeckLayerOptions {
  sites: SiteGeo[];
  conflictIds: Set<string>;
  cells: CoverageCell[];
  openCells: CoverageCell[];
  selectedVertical: string | null;
  showHeatmap: boolean;
  showProspecting: boolean;
  showZones: boolean;
  filterToVertical: boolean;
  showCapitals: boolean;
  showMetros: boolean;
  zoom: number;
  dataVersion: number;
  resolution: number;
}

/**
 * Build the deck overlay layers in the legibility-preserving z-order. Bottom →
 * top: wash → prospect → zones → pins → metro labels → capital labels. Reference
 * layers (capitals/metros) + zones are conditionally spread (omitted when off),
 * so with every reference toggle off the array equals the W4 composition exactly
 * (the byte-identical-first-paint invariant). Labels are LAST so they render
 * above pins; capitals after metros so a capital wins a collision. (ZCTA is NOT
 * here — it is a MapLibre-native source beneath the entire overlay.)
 */
export function buildDeckLayers(o: DeckLayerOptions) {
  const trigger = {
    selectedVertical: o.selectedVertical,
    dataVersion: o.dataVersion,
    resolution: o.resolution,
  };
  return [
    ...(o.showHeatmap && o.selectedVertical
      ? [saturationLayer(o.cells, trigger)]
      : []),
    ...(o.showProspecting && o.selectedVertical
      ? [prospectLayer(o.openCells, trigger)]
      : []),
    ...(o.showZones ? [siteZonesLayer(o.sites, o.conflictIds)] : []),
    sitePinsLayer(o.sites, {
      selectedVertical: o.selectedVertical,
      filterToVertical: o.filterToVertical,
    }),
    ...(o.showMetros && shouldShowMetros(o.zoom) ? [metrosLayer(metros)] : []),
    ...(o.showCapitals ? [capitalsLayer(capitals)] : []),
  ];
}
