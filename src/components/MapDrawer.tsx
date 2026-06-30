import { useCallback, useEffect, useId, useRef, useState } from 'react';
import type { Conflict } from '../lib/conflicts';
import { VERTICAL_OPTIONS, verticalLabel } from '../lib/customers';
import { verticalColor, verticalLegendRows, rgbCss } from '../lib/verticalStyle';
import { zctaSourceLabel } from './zctaSource';
import { CustomerForm } from './CustomerForm';
import { CustomerImport } from './CustomerImport';
import { CustomerList } from './CustomerList';

/**
 * The consolidated left drawer (CG left-menu redesign).
 *
 * Replaces the two prior floating panels (the left `.site-panel` CRUD + the
 * top-right `.saturation-panel` "Map layers") with ONE left drawer, top → bottom:
 *   (a) the vertical chooser — a MULTI-SELECT over `VERTICAL_OPTIONS` (native
 *       checkboxes, each `useId`-labeled, with a per-vertical color swatch). This
 *       is the PRIMARY gate: it drives which sites are visible on the map.
 *   (b) the Analysis-layer toggles (site zones, saturation heatmap, prospecting,
 *       ZIP) + the saturation legend + the vertical color legend + the
 *       `aria-live` summary + the jump-to-open button.
 *   (c) the customer CRUD (add form, CSV import, list) — rendered inside the
 *       scrollable drawer.
 *
 * Behavior: the drawer is OPEN on load and AUTO-RETRACTS after 15 s of no
 * interaction (slides off-screen left). Any hover / focus / input / click inside
 * resets the 15 s timer, and it never retracts while hovered or while it contains
 * focus (so it can't vanish mid-use). A persistent "Keep panel open" checkbox in
 * the header DISABLES the auto-retract entirely while checked (default unchecked,
 * preserving the 15 s behavior). It reopens via (a) a left-edge hover hot-zone
 * over the map and (b) a persistent, keyboard-focusable handle button — the
 * accessible reopen. Retracting hides only the menu; the selected verticals'
 * sites stay on the map.
 *
 * a11y contract (preserved from W3/W4/W5): `useId` on every control; native
 * `disabled` (never `aria-disabled`) on every gated control; the `aria-live`
 * summary seeded EMPTY when no active vertical; the ZIP toggle native-`disabled`
 * + `aria-describedby` its helper note when unconfigured; the drawer is a labeled
 * complementary landmark (`<aside aria-label="Map menu">` — a control panel, not
 * the page's dominant content, which is the map); the slide respects
 * `prefers-reduced-motion` (CSS); the closed drawer is `inert` (not a tab trap /
 * not focusable off-screen), and the reopen handle is focusable + labeled.
 *
 * Focus management (WCAG 2.4.3): activating the internal "Hide" button moves
 * focus to the now-visible reopen handle (the drawer becomes `inert`, so focus
 * cannot stay inside it); opening the drawer VIA THE HANDLE moves focus to the
 * first control inside (the first vertical checkbox). A hover-reopen (hot-zone)
 * does NOT steal focus.
 */

/** Retract after this long with no interaction (and not hovered/focused). */
const RETRACT_MS = 15000;

/** The discrete saturation legend rows (swatch hex + numeric label) — W4. */
const LEGEND_ROWS: ReadonlyArray<{ hex: string; label: string }> = [
  { hex: '#137333', label: 'Open (0 zones)' },
  { hex: '#c6dbef', label: '1 zone' },
  { hex: '#6baed6', label: '2 zones' },
  { hex: '#1558b0', label: '3+ zones' },
];

export interface MapDrawerProps {
  /** The multi-select gate — the verticals whose sites are shown on the map. */
  selectedVerticals: string[];
  /** The FIRST selected vertical (`selectedVerticals[0] ?? null`) — saturation
   * + prospecting + the legend/summary key on this one. */
  activeVertical: string | null;
  showHeatmap: boolean;
  showProspecting: boolean;
  showZones: boolean;
  showZcta: boolean;
  /** Whether a ZCTA tile source is configured (drives the ZIP toggle enable). */
  zctaConfigured: boolean;
  coveredCount: number;
  openCount: number;
  capped: boolean;
  computing: boolean;
  /** A transient action notice (e.g. the jump announce) shown in the aria-live
   * summary line, taking precedence until the next recompute. */
  announcement: string | null;
  onToggleVertical: (vertical: string, checked: boolean) => void;
  onToggleHeatmap: (on: boolean) => void;
  onToggleProspecting: (on: boolean) => void;
  onToggleZones: (on: boolean) => void;
  onToggleZcta: (on: boolean) => void;
  onJumpToOpen: () => void;
  // ---- Customer CRUD wiring (relocated from the old left .site-panel). ----
  onChanged: () => void;
  reloadVersion: number;
  conflictsBySite: Map<string, Conflict[]>;
  conflictsLoading: boolean;
}

export function MapDrawer({
  selectedVerticals,
  activeVertical,
  showHeatmap,
  showProspecting,
  showZones,
  showZcta,
  zctaConfigured,
  coveredCount,
  openCount,
  capped,
  computing,
  announcement,
  onToggleVertical,
  onToggleHeatmap,
  onToggleProspecting,
  onToggleZones,
  onToggleZcta,
  onJumpToOpen,
  onChanged,
  reloadVersion,
  conflictsBySite,
  conflictsLoading,
}: MapDrawerProps) {
  const drawerId = useId();
  const verticalsBaseId = useId();
  const zctaId = useId();
  const zctaNoteId = useId();
  const zonesId = useId();
  const heatmapId = useId();
  const prospectingId = useId();
  const legendId = useId();
  const keepOpenId = useId();

  // ---- Auto-retract / reopen state ----
  const [open, setOpen] = useState(true);
  // When checked, the drawer never auto-hides (A11Y-001 / WCAG 2.2.1) — gives a
  // user control over the 15 s timer. Default UNCHECKED so the requested 15 s
  // behavior is the out-of-box default. Session-scoped component state.
  const [keepOpen, setKeepOpen] = useState(false);
  const hoveredRef = useRef(false);
  const focusWithinRef = useRef(false);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  // The external reopen/collapse handle (focus lands here when "Hide" closes the
  // drawer — A11Y-003) and the first control inside (focus lands here when the
  // handle OPENS the drawer — A11Y-006).
  const handleBtnRef = useRef<HTMLButtonElement | null>(null);
  const firstControlRef = useRef<HTMLInputElement | null>(null);

  const clearTimer = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  // (Re)arm the 15 s inactivity timer. On fire it retracts ONLY when the drawer
  // is neither hovered nor holding focus — so it never vanishes mid-use; the
  // mouseleave / blur handlers re-arm a fresh window when hover/focus ends.
  const scheduleRetract = useCallback(() => {
    clearTimer();
    // "Keep panel open" disables the auto-retract entirely — never schedule the
    // timer while it is on (A11Y-001). Toggling it re-runs the arm effect below
    // (scheduleRetract identity changes), so turning it OFF re-arms a fresh 15 s
    // window and turning it ON clears any pending one.
    if (keepOpen) return;
    timerRef.current = setTimeout(() => {
      if (!hoveredRef.current && !focusWithinRef.current) {
        setOpen(false);
      }
    }, RETRACT_MS);
  }, [clearTimer, keepOpen]);

  // Arm on open; disarm on close. Cleanup clears any pending timer.
  useEffect(() => {
    if (open) {
      scheduleRetract();
    } else {
      clearTimer();
    }
    return clearTimer;
  }, [open, scheduleRetract, clearTimer]);

  // Any interaction inside the open drawer resets the 15 s window. (When closed
  // the drawer is `inert`, so these never fire from within it.)
  const handleInteract = useCallback(() => {
    if (open) {
      scheduleRetract();
    }
  }, [open, scheduleRetract]);

  const handleMouseEnter = useCallback(() => {
    hoveredRef.current = true;
    handleInteract();
  }, [handleInteract]);

  const handleMouseLeave = useCallback(() => {
    hoveredRef.current = false;
    handleInteract();
  }, [handleInteract]);

  const handleFocus = useCallback(() => {
    focusWithinRef.current = true;
    handleInteract();
  }, [handleInteract]);

  const handleBlur = useCallback(
    (e: React.FocusEvent<HTMLElement>) => {
      // Focus left the drawer entirely (no relatedTarget inside it).
      if (!e.currentTarget.contains(e.relatedTarget as Node | null)) {
        focusWithinRef.current = false;
      }
      handleInteract();
    },
    [handleInteract],
  );

  // Hover reopen (hot-zone): open WITHOUT stealing focus (A11Y-006 caveat — the
  // pointer user is already where they want to be).
  const openDrawer = useCallback(() => setOpen(true), []);

  // The handle button toggles the drawer. On OPEN it moves focus to the first
  // control inside so a keyboard user lands in the panel they just opened
  // (A11Y-006). On CLOSE focus simply stays on the handle (it is the activated
  // element and remains operable), so no extra focus move is needed.
  const toggleViaHandle = useCallback(() => {
    if (open) {
      setOpen(false);
    } else {
      setOpen(true);
      requestAnimationFrame(() => firstControlRef.current?.focus());
    }
  }, [open]);

  // The internal "Hide" button closes the drawer. Because `inert` then applies
  // to the drawer (its ancestor), focus would otherwise drop to <body>; move it
  // to the now-visible reopen handle instead (A11Y-003 — WCAG 2.4.3).
  const handleHide = useCallback(() => {
    setOpen(false);
    requestAnimationFrame(() => handleBtnRef.current?.focus());
  }, []);

  const noVertical = activeVertical === null;
  const label = verticalLabel(activeVertical);

  // The single aria-live summary line (W4). Seeded EMPTY when no active vertical
  // (no auto-announce at first paint); the static prompt below carries the cue.
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

  // The numeric legend keys BOTH the heatmap buckets AND the green prospect
  // outlines, so it shows whenever EITHER overlay is on (and a vertical active).
  const showLegend = !noVertical && (showHeatmap || showProspecting);
  const legendRows = verticalLegendRows();

  return (
    <>
      {/* The left-edge hover hot-zone (pointer reopen). Present only when closed
          so it never blocks map interaction while the drawer is open. aria-hidden
          because it is the keyboard-INACCESSIBLE reopen — the handle below is the
          accessible one. */}
      {!open && (
        <div
          className="map-drawer__hotzone"
          aria-hidden="true"
          onMouseEnter={openDrawer}
        />
      )}

      {/* The persistent, keyboard-focusable reopen / collapse handle. Lives
          OUTSIDE the sliding panel so it stays operable when the panel is
          off-screen. */}
      <button
        ref={handleBtnRef}
        type="button"
        className={`map-drawer__handle${open ? ' map-drawer__handle--open' : ''}`}
        aria-label={open ? 'Close map menu' : 'Open map menu'}
        aria-expanded={open}
        aria-controls={drawerId}
        onClick={toggleViaHandle}
      >
        <span aria-hidden="true">{open ? '‹' : '›'}</span>
      </button>

      <aside
        id={drawerId}
        className={`map-drawer${open ? '' : ' map-drawer--closed'}`}
        aria-label="Map menu"
        inert={!open}
        onPointerMove={handleInteract}
        onPointerDown={handleInteract}
        onKeyDownCapture={handleInteract}
        onInput={handleInteract}
        onMouseEnter={handleMouseEnter}
        onMouseLeave={handleMouseLeave}
        onFocusCapture={handleFocus}
        onBlurCapture={handleBlur}
      >
        <header className="map-drawer__header">
          <h2>Map menu</h2>
          <div className="map-drawer__header-controls">
            {/* A11Y-001 (WCAG 2.2.1): a user control over the 15 s auto-retract.
                Checked → the drawer never auto-hides. */}
            <div className="field-checkbox map-drawer__keep-open">
              <input
                id={keepOpenId}
                type="checkbox"
                checked={keepOpen}
                onChange={(e) => setKeepOpen(e.target.checked)}
              />
              <label htmlFor={keepOpenId}>Keep panel open</label>
            </div>
            <button
              type="button"
              className="btn-secondary map-drawer__collapse"
              aria-label="Hide map menu"
              onClick={handleHide}
            >
              Hide
            </button>
          </div>
        </header>

        {/* (a) The vertical chooser — the PRIMARY gate (multi-select). */}
        <fieldset className="layers-fieldset vertical-chooser">
          <legend>Verticals</legend>
          <p className="helper-text">
            Select verticals to show their sites on the map.
          </p>
          {VERTICAL_OPTIONS.map((o, i) => {
            const id = `${verticalsBaseId}-${o.value}`;
            return (
              <div className="field-checkbox" key={o.value}>
                <input
                  // The first control receives focus when the handle OPENS the
                  // drawer (A11Y-006).
                  ref={i === 0 ? firstControlRef : undefined}
                  id={id}
                  type="checkbox"
                  checked={selectedVerticals.includes(o.value)}
                  onChange={(e) => onToggleVertical(o.value, e.target.checked)}
                />
                <label htmlFor={id}>
                  <span
                    className="sat-legend__swatch vertical-chooser__swatch"
                    aria-hidden="true"
                    style={{ background: rgbCss(verticalColor(o.value)) }}
                  />
                  {o.label}
                </label>
              </div>
            );
          })}
        </fieldset>

        {/* (b) Analysis-layer toggles. */}
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

          <div className="field-checkbox">
            <input
              id={zctaId}
              type="checkbox"
              checked={showZcta}
              disabled={!zctaConfigured}
              aria-describedby={!zctaConfigured ? zctaNoteId : undefined}
              onChange={(e) => onToggleZcta(e.target.checked)}
            />
            <label htmlFor={zctaId}>ZIP boundaries ({zctaSourceLabel()})</label>
          </div>
          {!zctaConfigured && (
            <p id={zctaNoteId} className="helper-text">
              Configure a ZCTA tile source (VITE_ZCTA_TILES_URL) to enable.
            </p>
          )}
        </fieldset>

        <details>
          <summary>Vertical colors</summary>
          <ul className="vertical-legend" id={legendId} role="list">
            {legendRows.map((row) => (
              <li key={row.label}>
                {/* The swatch is decorative; the text label is the SR carrier
                    (never color-alone). The per-vertical color is the sanctioned
                    data-driven inline style (mirrors the W4 swatch). */}
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
          <ul className="sat-legend" role="list">
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
          // The "select a vertical" prompt is STATIC (non-live) so it is not
          // auto-announced at first paint; the live region below stays seeded
          // empty until a real saturation state flows through it.
          <p className="helper-text">
            Select a vertical to view saturation.
          </p>
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

        {/* (c) Customer CRUD — relocated into the scrollable drawer. No
            landmark label here: CustomerList already exposes its own Customers
            section landmark, so labeling this OUTER wrapper too would list
            "Customers" twice in screen-reader landmark nav (A11Y-005). Leaving
            it unlabeled drops the wrapper from the landmark list. */}
        <section className="map-drawer__crud">
          <CustomerForm onChanged={onChanged} />
          <CustomerImport onChanged={onChanged} />
          <CustomerList
            onChanged={onChanged}
            reloadVersion={reloadVersion}
            conflictsBySite={conflictsBySite}
            conflictsLoading={conflictsLoading}
          />
        </section>
      </aside>
    </>
  );
}
