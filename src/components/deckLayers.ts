import type { Layer } from 'deck.gl';
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
  /**
   * The multi-select vertical chooser — the gate for site visibility. Empty =>
   * NO pins/zones (default load shows just the basemap). Saturation/prospecting
   * apply to the FIRST selected vertical (`selectedVerticals[0]`).
   */
  selectedVerticals: string[];
  showHeatmap: boolean;
  showProspecting: boolean;
  showZones: boolean;
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
 * so with every reference toggle off the array equals the prior composition
 * exactly (the byte-identical-first-paint invariant). Labels are LAST so they
 * render above pins; capitals after metros so a capital wins a collision. (ZCTA
 * is NOT here — it is a MapLibre-native source beneath the entire overlay.)
 *
 * The multi-select drives visibility: pins filter to `selectedVerticals`, and the
 * zones layer is fed only the VISIBLE (selected-vertical) located sites so a
 * zone never renders for a hidden site. Saturation/prospecting key on the FIRST
 * selected vertical (`activeVertical`); with no selection neither overlay shows.
 */
export function buildDeckLayers(o: DeckLayerOptions): Layer[] {
  const activeVertical = o.selectedVerticals[0] ?? null;
  const trigger = {
    selectedVertical: activeVertical,
    dataVersion: o.dataVersion,
    resolution: o.resolution,
  };
  // Only the visible (selected-vertical) sites contribute zones; conflict
  // coloring still reads the whole-tenant `conflictIds` set, so a visible site
  // in conflict reads red while hidden sites contribute no circles at all.
  const visibleSites = o.sites.filter(
    (s) => s.vertical != null && o.selectedVerticals.includes(s.vertical),
  );
  return [
    ...(o.showHeatmap && activeVertical
      ? [saturationLayer(o.cells, trigger)]
      : []),
    ...(o.showProspecting && activeVertical
      ? [prospectLayer(o.openCells, trigger)]
      : []),
    ...(o.showZones ? [siteZonesLayer(visibleSites, o.conflictIds)] : []),
    sitePinsLayer(o.sites, { selectedVerticals: o.selectedVerticals }),
    ...(o.showMetros && shouldShowMetros(o.zoom) ? [metrosLayer(metros)] : []),
    ...(o.showCapitals ? [capitalsLayer(capitals)] : []),
  ];
}
