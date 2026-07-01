import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react';
import { cellToLatLng } from 'h3-js';
import { AuthGate } from './components/AuthGate';
import { MapShell } from './components/MapShell';
import { MapDrawer } from './components/MapDrawer';
import { SitesView } from './components/SitesView';
import { zctaConfigured } from './components/zctaSource';
import { supabase } from './lib/supabaseClient';
import type { SiteGeo } from './lib/customers';
import { findSiteConflicts, type Conflict } from './lib/conflicts';
import {
  computeSaturation,
  type LatLng,
  type SaturationResult,
  type ViewportBounds,
} from './lib/coverage';

/**
 * App composition (AC-010 / AC-011 / AC-015 / AC-020 + EX-T5 AC-022/AC-024).
 *
 * App is the OWNER of the lifted `sites` state (the reactive map-data seam,
 * AC-010): it loads `site_geo` (RLS-auto-scoped) and passes `sites` to
 * `MapShell`. App also owns the derived EXCLUSIVITY-CONFLICT state: after each
 * sites load it runs a whole-tenant conflict pass (one `findSiteConflicts` per
 * located site) and builds `conflictsBySite` — recomputed on DATA CHANGE, never
 * per frame (ADR perf). `conflictIds` (its keys) drives the zone recolor in
 * `MapShell`; `conflictsBySite` + `conflictsLoading` drive the SiteRow
 * zone-status + neighbor detail in `CustomerList`. `reload` re-fetches sites AND
 * re-derives conflicts AND bumps a version that re-fetches `CustomerList`, so any
 * add/edit/move/delete/radius-change reflects on the map and in the list with no
 * page reload (AC-024 passive recolor — no modal on a radius change).
 */

/** Whole-tenant conflict pass: site_id → its conflicts (only non-empty entries). */
async function computeConflicts(
  sites: SiteGeo[],
): Promise<Map<string, Conflict[]>> {
  const located = sites.filter((s) => s.lat != null && s.lng != null);
  const results = await Promise.all(
    located.map(async (s) => [s.id, await findSiteConflicts(s.id)] as const),
  );
  const map = new Map<string, Conflict[]>();
  for (const [id, conflicts] of results) {
    if (conflicts.length > 0) {
      map.set(id, conflicts);
    }
  }
  return map;
}

/** The current map viewport emitted by MapShell's debounced moveend seam. */
interface Viewport {
  bounds: ViewportBounds;
  zoom: number;
  center: LatLng;
}

/** The empty saturation result (no vertical / no viewport / capped reset). */
const EMPTY_SATURATION: SaturationResult = {
  cells: [],
  openCells: [],
  coveredCount: 0,
  openCount: 0,
  capped: false,
  resolution: 0,
};

export function App() {
  // Top-level view toggle: 'map' = MapShell + MapDrawer (the default); 'sites' =
  // the full-width SitesView data table (drawer + map hidden). The signed-in
  // header (with the toggle + sign-out) stays in both views.
  const [view, setView] = useState<'map' | 'sites'>('map');
  const viewToggleLabelId = useId();

  const [sites, setSites] = useState<SiteGeo[]>([]);
  const [version, setVersion] = useState(0);
  const [conflictsBySite, setConflictsBySite] = useState<
    Map<string, Conflict[]>
  >(new Map());
  const [conflictsLoading, setConflictsLoading] = useState(false);

  // The conflict-id set (every conflicting site) the map layer recolors on.
  const conflictIds = useMemo(
    () => new Set(conflictsBySite.keys()),
    [conflictsBySite],
  );

  // ---- Saturation + layer state lifted alongside conflictIds. ----
  // The left-menu redesign replaces the single `selectedVertical` + opt-in
  // `filterToVertical` with a MULTI-SELECT `selectedVerticals` (default []): the
  // chooser IS the gate for site visibility. Saturation/prospecting apply to the
  // FIRST selected vertical (`activeVertical`); empty selection => no sites, no
  // heatmap. Defaults: ZCTA OFF, zones ON.
  const [selectedVerticals, setSelectedVerticals] = useState<string[]>([]);
  const [showHeatmap, setShowHeatmap] = useState(true);
  const [showProspecting, setShowProspecting] = useState(false);
  const [showZcta, setShowZcta] = useState(false);
  const [showZones, setShowZones] = useState(true);

  // Saturation/prospecting/legend/summary key on the FIRST selected vertical.
  const activeVertical = selectedVerticals[0] ?? null;
  // Whether a ZCTA tile source is configured (env-only; constant per session) —
  // drives the panel's ZIP toggle enable/disable (graceful degrade — RO-T4).
  const zctaIsConfigured = zctaConfigured();
  const [viewport, setViewport] = useState<Viewport | null>(null);
  const [saturation, setSaturation] = useState<SaturationResult>(EMPTY_SATURATION);
  const [computing, setComputing] = useState(false);
  const [flyToTarget, setFlyToTarget] = useState<LatLng | null>(null);
  const [announcement, setAnnouncement] = useState<string | null>(null);

  // Recompute is signalled "computing" from the EVENT handlers (a vertical change
  // or a debounced moveend), not from the effect body — so the
  // "Computing saturation…" state paints (AC-026) without a synchronous setState
  // in the effect.
  const handleViewportChange = useCallback(
    (bounds: ViewportBounds, zoom: number, center: LatLng) => {
      setComputing(true);
      setViewport({ bounds, zoom, center });
    },
    [],
  );

  // Toggle a vertical in/out of the multi-select gate. (Pure membership update;
  // the "Computing saturation…" paint is driven by the activeVertical-change
  // effect below so a synchronous setState never runs in the updater.)
  const handleToggleVertical = useCallback(
    (vertical: string, checked: boolean) => {
      setSelectedVerticals((prev) => {
        if (checked) {
          return prev.includes(vertical) ? prev : [...prev, vertical];
        }
        return prev.filter((v) => v !== vertical);
      });
    },
    [],
  );

  // Paint the "Computing saturation…" state the moment the ACTIVE vertical
  // changes to a non-null token (toggling a non-first vertical leaves the active
  // one unchanged → no recompute). Runs after paint, so the recompute effect
  // below clears it. Mirrors the viewport-change "computing" signal.
  const prevActiveRef = useRef<string | null>(null);
  useEffect(() => {
    if (activeVertical !== null && activeVertical !== prevActiveRef.current) {
      setComputing(true);
    }
    prevActiveRef.current = activeVertical;
  }, [activeVertical]);

  // Viewport-bounded coverage recompute — reacts to viewport (debounced moveend),
  // the ACTIVE vertical, and data reload (`version`); NEVER per render/frame
  // (mirrors the conflictIds "recompute on data change" posture). The
  // (synchronous, pure) compute is deferred a macrotask so the "Computing
  // saturation…" state paints first, and is cancellable so a rapid change never
  // writes stale cells. Each recompute clears any transient jump announcement.
  useEffect(() => {
    let cancelled = false;
    const id = setTimeout(() => {
      if (cancelled) {
        return;
      }
      setAnnouncement(null);
      if (activeVertical === null || viewport === null) {
        setSaturation(EMPTY_SATURATION);
        setComputing(false);
        return;
      }
      setSaturation(
        computeSaturation({
          sites,
          selectedVertical: activeVertical,
          bounds: viewport.bounds,
          zoom: viewport.zoom,
          center: viewport.center,
          // PR-002: only pay the ranked open-cell cost when the prospecting
          // overlay is on (the layer is its only reactive consumer). `openCount`
          // is computed regardless, so the summary is unaffected.
          wantOpenCells: showProspecting,
        }),
      );
      setComputing(false);
    }, 0);
    return () => {
      cancelled = true;
      clearTimeout(id);
    };
  }, [sites, activeVertical, viewport, version, showProspecting]);

  // AC-016: ease the map to the nearest open cell's centroid + announce it via
  // the panel aria-live summary; the post-jump recompute clears the announce.
  const handleJumpToOpen = useCallback(() => {
    // The ranked open cells are precomputed only when prospecting is active
    // (PR-002); when it is off, derive just the nearest open cell on demand from
    // the current viewport so jump-to-open keeps working without paying the rank
    // cost on every recompute.
    let nearest = saturation.openCells[0];
    if (!nearest && viewport !== null && activeVertical !== null) {
      nearest = computeSaturation({
        sites,
        selectedVertical: activeVertical,
        bounds: viewport.bounds,
        zoom: viewport.zoom,
        center: viewport.center,
        wantOpenCells: true,
      }).openCells[0];
    }
    if (!nearest) {
      return;
    }
    const [lat, lng] = cellToLatLng(nearest.h3);
    setFlyToTarget({ lat, lng });
    setAnnouncement('Centered on nearest open area.');
  }, [saturation.openCells, viewport, sites, activeVertical]);

  const reload = useCallback(async () => {
    const { data } = await supabase.from('site_geo').select('*').order('name');
    const next = (data ?? []) as SiteGeo[];
    setSites(next);
    setVersion((v) => v + 1);
    setConflictsLoading(true);
    try {
      setConflictsBySite(await computeConflicts(next));
    } finally {
      setConflictsLoading(false);
    }
  }, []);

  // Initial load: fetch inside the effect (after an await) so setState is never
  // called synchronously in the effect body.
  useEffect(() => {
    let cancelled = false;
    async function load() {
      const { data } = await supabase.from('site_geo').select('*').order('name');
      if (cancelled) {
        return;
      }
      const next = (data ?? []) as SiteGeo[];
      setSites(next);
      setVersion((v) => v + 1);
      setConflictsLoading(true);
      try {
        const map = await computeConflicts(next);
        if (!cancelled) {
          setConflictsBySite(map);
        }
      } finally {
        if (!cancelled) {
          setConflictsLoading(false);
        }
      }
    }
    void load();
    return () => {
      cancelled = true;
    };
  }, []);

  // The Map ⇄ Sites toggle, rendered into the AuthGate header slot. Native
  // segmented buttons with aria-pressed + a useId-labelled group (no ARIA
  // widget reinvention; keyboard-operable via the native buttons).
  const viewToggle = (
    <div
      className="view-toggle"
      role="group"
      aria-labelledby={viewToggleLabelId}
    >
      <span id={viewToggleLabelId} className="view-toggle__label">
        View
      </span>
      <button
        type="button"
        className="view-toggle__btn"
        aria-pressed={view === 'map'}
        onClick={() => setView('map')}
      >
        Map
      </button>
      <button
        type="button"
        className="view-toggle__btn"
        aria-pressed={view === 'sites'}
        onClick={() => setView('sites')}
      >
        Sites
      </button>
    </div>
  );

  return (
    <AuthGate headerSlot={viewToggle}>
      <div className="app-shell">
        {view === 'map' ? (
          <>
            <MapShell
              sites={sites}
              conflictIds={conflictIds}
              cells={saturation.cells}
              openCells={saturation.openCells}
              selectedVerticals={selectedVerticals}
              showHeatmap={showHeatmap}
              showProspecting={showProspecting}
              showZones={showZones}
              showZcta={showZcta}
              dataVersion={version}
              resolution={saturation.resolution}
              onViewportChange={handleViewportChange}
              flyToTarget={flyToTarget}
            />
            {/* The ONE consolidated left drawer: vertical chooser (the gate) →
                layer toggles + saturation legend/summary → customer CRUD.
                Auto-retracts after 15 s idle and reopens on left-edge hover + a
                focusable handle. Replaces the old left .site-panel CRUD + the
                top-right .saturation-panel as separate floating surfaces. */}
            <MapDrawer
              selectedVerticals={selectedVerticals}
              activeVertical={activeVertical}
              showHeatmap={showHeatmap}
              showProspecting={showProspecting}
              showZones={showZones}
              showZcta={showZcta}
              zctaConfigured={zctaIsConfigured}
              coveredCount={saturation.coveredCount}
              openCount={saturation.openCount}
              capped={saturation.capped}
              computing={computing}
              announcement={announcement}
              onToggleVertical={handleToggleVertical}
              onToggleHeatmap={setShowHeatmap}
              onToggleProspecting={setShowProspecting}
              onToggleZones={setShowZones}
              onToggleZcta={setShowZcta}
              onJumpToOpen={handleJumpToOpen}
              onChanged={() => void reload()}
              reloadVersion={version}
              conflictsBySite={conflictsBySite}
              conflictsLoading={conflictsLoading}
            />
          </>
        ) : (
          // Sites view: the full-width editable table. It bumps the SAME shared
          // reload version on save, so the map reflects every fix on switch-back.
          <SitesView onChanged={() => void reload()} reloadVersion={version} />
        )}
      </div>
    </AuthGate>
  );
}
