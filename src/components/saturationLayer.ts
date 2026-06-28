import { H3HexagonLayer } from 'deck.gl';
import type { CoverageCell } from '../lib/coverage';

/**
 * The area-saturation deck.gl layers (AS-T3 — AC-014/017/019).
 *
 * Two builders mirroring the `siteZonesLayer.ts` factory shape (data filter →
 * layer config → `updateTriggers` with a stable key). `H3HexagonLayer` comes
 * from the `deck.gl` umbrella (which re-exports `@deck.gl/geo-layers`), exactly
 * as `ScatterplotLayer` already does — `h3-js` is the direct compute dep, the
 * layer is NOT relied on transitively (AC-028).
 *
 * `saturationLayer` is the overlap-weighted coverage WASH: a flat
 * (`extruded:false`), passive (`pickable:false`) hex fill keyed on per-cell
 * coverage via a DISCRETE Blues ramp (1 / 2 / 3+ — never a continuous gradient,
 * never red; ui-spec §4). `prospectLayer` is the green-outline highlight of the
 * zero-coverage (open) cells (ui-spec §7). Both are mounted by `MapShell` UNDER
 * the W3 zones + pins (AS-T4); coloring + presence are reinforcement — the
 * authoritative SR-readable signal is the SaturationPanel legend + summary.
 */

/**
 * The key that drives deck.gl's accessor-memo so the fill accessor re-evaluates
 * only on a REAL change — vertical / data reload / resolution (AC-014). Mirrors
 * `siteZonesLayer`'s `conflictKey` stable-key idiom; never per frame.
 */
export interface LayerTriggerKey {
  selectedVertical: string | null;
  dataVersion: number;
  resolution: number;
}

/**
 * The discrete Blues ramp (ui-spec §4). `data` is pre-filtered to `coverage >= 1`
 * so coverage 0 never reaches this accessor; coverage 4+ clamps to the 3+ bucket.
 */
function fillForCoverage(coverage: number): [number, number, number, number] {
  if (coverage >= 3) {
    return [21, 88, 176, 190]; // #1558b0 — the W3 zone blue (deepest bucket)
  }
  if (coverage === 2) {
    return [107, 174, 214, 170]; // #6baed6
  }
  return [198, 219, 239, 150]; // #c6dbef — coverage 1
}

/**
 * AS-T3 / AC-017 — the saturation wash. `data` is only covered cells
 * (`coverage >= 1`); open cells are excluded here (the basemap shows through and
 * `prospectLayer` renders them). Flat, filled, unstroked, unpickable.
 */
export function saturationLayer(
  cells: CoverageCell[],
  trigger: LayerTriggerKey,
): H3HexagonLayer<CoverageCell> {
  // PR-003: `computeSaturation` already returns only coverage>=1 cells, so this
  // is redundant on the production path. It is RETAINED as the defensive contract
  // for the standalone test path (saturationLayer.test.ts passes mixed-coverage
  // input directly and asserts open cells are filtered out of the wash data).
  const covered = cells.filter((c) => c.coverage >= 1);
  return new H3HexagonLayer<CoverageCell>({
    id: 'saturation',
    data: covered,
    getHexagon: (d) => d.h3,
    extruded: false,
    filled: true,
    stroked: false,
    pickable: false,
    getFillColor: (d) => fillForCoverage(d.coverage),
    updateTriggers: {
      getFillColor: [
        trigger.selectedVertical,
        trigger.dataVersion,
        trigger.resolution,
      ],
    },
  });
}

/**
 * AS-T3 / AC-019 — the prospecting (open-area) highlight. A faint green wash with
 * a crisp green outline (`#137333` — deliberately NOT red, which is reserved for
 * W3 conflict) over the top-N nearest zero-coverage cells.
 */
export function prospectLayer(
  openCells: CoverageCell[],
  trigger: LayerTriggerKey,
): H3HexagonLayer<CoverageCell> {
  return new H3HexagonLayer<CoverageCell>({
    id: 'prospect',
    data: openCells,
    getHexagon: (d) => d.h3,
    extruded: false,
    filled: true,
    getFillColor: [19, 115, 51, 35],
    stroked: true,
    getLineColor: [19, 115, 51, 230],
    getLineWidth: 2,
    lineWidthUnits: 'pixels',
    pickable: false,
    updateTriggers: {
      getFillColor: [
        trigger.selectedVertical,
        trigger.dataVersion,
        trigger.resolution,
      ],
      getLineColor: [
        trigger.selectedVertical,
        trigger.dataVersion,
        trigger.resolution,
      ],
    },
  });
}
