import { useId } from 'react';
import { VERTICAL_OPTIONS, verticalLabel } from '../lib/customers';
import { verticalLegendRows, rgbCss } from '../lib/verticalStyle';

/**
 * The floating top-right "Map layers" control panel (W4 AS-T5 + RO-T6).
 *
 * A CONTROLLED component — all state is lifted to `App`; this panel renders props
 * + calls the setters. Wave 5 refactors it IN PLACE (keeping the
 * `.saturation-panel` glass shell + the left CRUD panel untouched) into the one
 * consolidated map-layer panel: the heading is "Map layers", the shared vertical
 * select is relabeled "Vertical" (the ONE vertical control — it drives saturation
 * AND, when the filter is on, the pin filter), an opt-in "show only this
 * vertical's sites" checkbox, two `<fieldset>` toggle groups (Reference /
 * Analysis), and a collapsible vertical color legend. The W4 numeric saturation
 * legend + `aria-live` summary + jump button are KEPT.
 *
 * The W4 a11y contract is preserved VERBATIM: `useId` on every control; native
 * `disabled` (never `aria-disabled`) on every gated control; the `aria-live`
 * summary seeded EMPTY when no vertical is selected. The ZIP toggle is native
 * `disabled` + `aria-describedby` a helper note when no ZCTA source is configured
 * (graceful degrade — RO-T4).
 */

export interface SaturationPanelProps {
  selectedVertical: string | null;
  showHeatmap: boolean;
  showProspecting: boolean;
  // RO-T6: the new layer toggles (lifted to App alongside the W4 state — RO-T7).
  // Optional with safe defaults so the panel compiles before the App wiring lands
  // (the RO-T7 dependant); App passes all of them once wired.
  filterToVertical?: boolean;
  showCapitals?: boolean;
  showMetros?: boolean;
  showZcta?: boolean;
  showZones?: boolean;
  /** Whether a ZCTA tile source is configured (drives the ZIP toggle enable). */
  zctaConfigured?: boolean;
  coveredCount: number;
  openCount: number;
  capped: boolean;
  computing: boolean;
  /** A transient action notice (e.g. the AS-T6 jump announce) shown in the
   * aria-live summary line, taking precedence until the next recompute. */
  announcement?: string | null;
  onSelectVertical: (vertical: string | null) => void;
  onToggleHeatmap: (on: boolean) => void;
  onToggleProspecting: (on: boolean) => void;
  onToggleFilter?: (on: boolean) => void;
  onToggleCapitals?: (on: boolean) => void;
  onToggleMetros?: (on: boolean) => void;
  onToggleZcta?: (on: boolean) => void;
  onToggleZones?: (on: boolean) => void;
  onJumpToOpen: () => void;
}

/** The discrete saturation legend rows (swatch hex + numeric label) — W4. */
const LEGEND_ROWS: ReadonlyArray<{ hex: string; label: string }> = [
  { hex: '#137333', label: 'Open (0 zones)' },
  { hex: '#c6dbef', label: '1 zone' },
  { hex: '#6baed6', label: '2 zones' },
  { hex: '#1558b0', label: '3+ zones' },
];

export function SaturationPanel({
  selectedVertical,
  showHeatmap,
  showProspecting,
  filterToVertical = false,
  showCapitals = false,
  showMetros = false,
  showZcta = false,
  showZones = true,
  zctaConfigured = false,
  coveredCount,
  openCount,
  capped,
  computing,
  announcement = null,
  onSelectVertical,
  onToggleHeatmap,
  onToggleProspecting,
  onToggleFilter = () => {},
  onToggleCapitals = () => {},
  onToggleMetros = () => {},
  onToggleZcta = () => {},
  onToggleZones = () => {},
  onJumpToOpen,
}: SaturationPanelProps) {
  const verticalId = useId();
  const filterId = useId();
  const capitalsId = useId();
  const metrosId = useId();
  const zctaId = useId();
  const zctaNoteId = useId();
  const zonesId = useId();
  const heatmapId = useId();
  const prospectingId = useId();
  const legendId = useId();

  const noVertical = selectedVertical === null;
  const label = verticalLabel(selectedVertical);

  // The single aria-live summary line (W4 AC-025/026). A11Y-002: seeded EMPTY
  // when no vertical is selected (the screen reader does not auto-announce at
  // first paint); the "Select a vertical…" prompt is STATIC text below.
  let summary = '';
  if (!noVertical) {
    if (announcement) {
      summary = announcement;
    } else if (computing) {
      summary = 'Computing saturation…';
    } else if (capped) {
      summary = 'Zoom in to compute saturation';
    } else if (coveredCount === 0) {
      summary = `No ${label} zones in this area — all open.`;
    } else {
      summary = `Saturation for ${label}: ${coveredCount} covered cells, ${openCount} open cells near center.`;
    }
  }

  // A11Y-001 (W4): the numeric legend is the key for BOTH the heatmap buckets AND
  // the green prospect outlines, so it shows whenever EITHER overlay is on.
  const showLegend = !noVertical && (showHeatmap || showProspecting);

  const legendRows = verticalLegendRows();

  return (
    <aside className="saturation-panel" aria-label="Map layer controls">
      <h2>Map layers</h2>

      <div className="field">
        <label htmlFor={verticalId}>Vertical</label>
        <select
          id={verticalId}
          value={selectedVertical ?? ''}
          onChange={(e) => onSelectVertical(e.target.value || null)}
        >
          <option value="">Select vertical…</option>
          {VERTICAL_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
      </div>

      <div className="field-checkbox">
        <input
          id={filterId}
          type="checkbox"
          checked={filterToVertical}
          disabled={noVertical}
          onChange={(e) => onToggleFilter(e.target.checked)}
        />
        <label htmlFor={filterId}>Show only this vertical&apos;s sites</label>
      </div>

      <fieldset className="layers-fieldset">
        <legend>Reference layers</legend>

        <div className="field-checkbox">
          <input
            id={capitalsId}
            type="checkbox"
            checked={showCapitals}
            onChange={(e) => onToggleCapitals(e.target.checked)}
          />
          <label htmlFor={capitalsId}>State capitals</label>
        </div>

        <div className="field-checkbox">
          <input
            id={metrosId}
            type="checkbox"
            checked={showMetros}
            onChange={(e) => onToggleMetros(e.target.checked)}
          />
          <label htmlFor={metrosId}>Metro areas</label>
        </div>

        <div className="field-checkbox">
          <input
            id={zctaId}
            type="checkbox"
            checked={showZcta}
            disabled={!zctaConfigured}
            aria-describedby={!zctaConfigured ? zctaNoteId : undefined}
            onChange={(e) => onToggleZcta(e.target.checked)}
          />
          <label htmlFor={zctaId}>ZIP / ZCTA boundaries</label>
        </div>
        {!zctaConfigured && (
          <p id={zctaNoteId} className="helper-text">
            Configure a ZCTA tile source (VITE_ZCTA_TILES_URL) to enable.
          </p>
        )}
      </fieldset>

      <fieldset className="layers-fieldset">
        <legend>Analysis layers</legend>

        <div className="field-checkbox">
          <input
            id={zonesId}
            type="checkbox"
            checked={showZones}
            onChange={(e) => onToggleZones(e.target.checked)}
          />
          <label htmlFor={zonesId}>Site zones</label>
        </div>

        <div className="field-checkbox">
          <input
            id={heatmapId}
            type="checkbox"
            checked={showHeatmap}
            disabled={noVertical}
            onChange={(e) => onToggleHeatmap(e.target.checked)}
          />
          <label htmlFor={heatmapId}>Saturation heatmap</label>
        </div>

        <div className="field-checkbox">
          <input
            id={prospectingId}
            type="checkbox"
            checked={showProspecting}
            disabled={noVertical}
            onChange={(e) => onToggleProspecting(e.target.checked)}
          />
          <label htmlFor={prospectingId}>Highlight open areas</label>
        </div>
      </fieldset>

      <details>
        <summary aria-controls={legendId}>Vertical colors</summary>
        <ul className="vertical-legend" id={legendId}>
          {legendRows.map((row) => (
            <li key={row.label}>
              {/* The swatch is decorative; the text label is the SR carrier
                  (never color-alone). The dynamic per-vertical color is the one
                  sanctioned data-driven inline style (mirrors the W4 swatch). */}
              <span
                className="sat-legend__swatch"
                aria-hidden="true"
                style={{ background: rgbCss(row.color) }}
              />
              {row.label}
            </li>
          ))}
        </ul>
      </details>

      {showLegend && (
        <ul className="sat-legend">
          {LEGEND_ROWS.map((row) => (
            <li key={row.label}>
              <span
                className="sat-legend__swatch"
                aria-hidden="true"
                style={{ background: row.hex }}
              />
              {row.label}
            </li>
          ))}
        </ul>
      )}

      {noVertical && (
        // A11Y-002: the "select a vertical" prompt is STATIC (non-live) so it is
        // not auto-announced at first paint; the live region below stays seeded
        // empty until a real saturation state flows through it.
        <p className="helper-text">Select a vertical to view saturation.</p>
      )}

      <p className="helper-text" aria-live="polite">
        {summary}
      </p>

      <button
        type="button"
        className="btn-secondary"
        disabled={noVertical || openCount === 0}
        onClick={onJumpToOpen}
      >
        Jump to nearest open area
      </button>
    </aside>
  );
}
