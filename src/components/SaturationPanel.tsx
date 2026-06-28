import { useId } from 'react';
import { VERTICAL_OPTIONS, verticalLabel } from '../lib/customers';

/**
 * The floating top-right saturation control panel (AS-T5 — AC-021..027/029).
 *
 * A CONTROLLED component — all state (selectedVertical / showHeatmap /
 * showProspecting) is lifted to `App` (AS-T6, alongside the W3 `conflictIds`
 * pattern); this panel only renders props + calls the setters. It mirrors the
 * `.site-panel` glass treatment at the free top-right corner and leaves the left
 * CRUD panel untouched.
 *
 * The canvas heatmap is not SR-accessible by nature (the map is
 * `role="application"`); the accessible path is THIS chrome — a numeric legend
 * (never color-alone) + an `aria-live="polite"` textual summary carrying the
 * covered/open counts (AC-024/025), mirroring W3's chrome-scoped a11y. All
 * controls are native with `useId` labels and inherit the global
 * `:focus-visible`; gated toggles use the native `disabled` attribute, never
 * `aria-disabled` (AC-023/027).
 */

export interface SaturationPanelProps {
  selectedVertical: string | null;
  showHeatmap: boolean;
  showProspecting: boolean;
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
  onJumpToOpen: () => void;
}

/** The discrete legend rows (swatch hex + numeric label) — ui-spec §4/§8. */
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
  coveredCount,
  openCount,
  capped,
  computing,
  announcement = null,
  onSelectVertical,
  onToggleHeatmap,
  onToggleProspecting,
  onJumpToOpen,
}: SaturationPanelProps) {
  const verticalId = useId();
  const heatmapId = useId();
  const prospectingId = useId();

  const noVertical = selectedVertical === null;
  const label = verticalLabel(selectedVertical);

  // The single aria-live summary line — the SR carrier of the canvas (AC-025) +
  // the computing/cap/empty states (AC-026). A transient action announcement
  // (AS-T6 jump) takes precedence until the next recompute clears it.
  let summary: string;
  if (announcement) {
    summary = announcement;
  } else if (noVertical) {
    summary = 'Select a vertical to view saturation.';
  } else if (computing) {
    summary = 'Computing saturation…';
  } else if (capped) {
    summary = 'Zoom in to compute saturation';
  } else if (coveredCount === 0) {
    summary = `No ${label} zones in this area — all open.`;
  } else {
    summary = `Saturation for ${label}: ${coveredCount} covered cells, ${openCount} open cells near center.`;
  }

  const showLegend = !noVertical && showHeatmap;

  return (
    <aside className="saturation-panel" aria-label="Saturation controls">
      <h2>Saturation</h2>

      <div className="field">
        <label htmlFor={verticalId}>Saturation vertical</label>
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
          id={heatmapId}
          type="checkbox"
          checked={showHeatmap}
          disabled={noVertical}
          onChange={(e) => onToggleHeatmap(e.target.checked)}
        />
        <label htmlFor={heatmapId}>Show saturation heatmap</label>
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

      {showLegend && (
        <ul className="sat-legend">
          {LEGEND_ROWS.map((row) => (
            <li key={row.label}>
              {/* The swatch is decorative; the numeric label is the SR carrier
                  (never color-alone). The dynamic bucket color is the one
                  sanctioned data-driven inline style (AC-029). */}
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
