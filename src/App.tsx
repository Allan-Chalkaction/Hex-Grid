import { useCallback, useEffect, useMemo, useState } from 'react';
import { cellToLatLng } from 'h3-js';
import { AuthGate } from './components/AuthGate';
import { MapShell } from './components/MapShell';
import { CustomerForm } from './components/CustomerForm';
import { CustomerImport } from './components/CustomerImport';
import { CustomerList } from './components/CustomerList';
import { SaturationPanel } from './components/SaturationPanel';
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

  // ---- Wave 4 (AS-T6): saturation state lifted alongside conflictIds. ----
  const [selectedVertical, setSelectedVertical] = useState<string | null>(null);
  const [showHeatmap, setShowHeatmap] = useState(true);
  const [showProspecting, setShowProspecting] = useState(false);
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

  const handleSelectVertical = useCallback((vertical: string | null) => {
    if (vertical !== null) {
      setComputing(true);
    }
    setSelectedVertical(vertical);
  }, []);

  // Viewport-bounded coverage recompute — reacts to viewport (debounced moveend),
  // selectedVertical, and data reload (`version`); NEVER per render/frame (mirrors
  // the conflictIds "recompute on data change" posture). The (synchronous, pure)
  // compute is deferred a macrotask so the "Computing saturation…" state paints
  // first, and is cancellable so a rapid change never writes stale cells. Each
  // recompute clears any transient jump announcement.
  useEffect(() => {
    let cancelled = false;
    const id = setTimeout(() => {
      if (cancelled) {
        return;
      }
      setAnnouncement(null);
      if (selectedVertical === null || viewport === null) {
        setSaturation(EMPTY_SATURATION);
        setComputing(false);
        return;
      }
      setSaturation(
        computeSaturation({
          sites,
          selectedVertical,
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
  }, [sites, selectedVertical, viewport, version, showProspecting]);

  // AC-016: ease the map to the nearest open cell's centroid + announce it via
  // the panel aria-live summary; the post-jump recompute clears the announce.
  const handleJumpToOpen = useCallback(() => {
    // The ranked open cells are precomputed only when prospecting is active
    // (PR-002); when it is off, derive just the nearest open cell on demand from
    // the current viewport so jump-to-open keeps working without paying the rank
    // cost on every recompute.
    let nearest = saturation.openCells[0];
    if (!nearest && viewport !== null && selectedVertical !== null) {
      nearest = computeSaturation({
        sites,
        selectedVertical,
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
  }, [saturation.openCells, viewport, sites, selectedVertical]);

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

  return (
    <AuthGate>
      <div className="app-shell">
        <MapShell
          sites={sites}
          conflictIds={conflictIds}
          cells={saturation.cells}
          openCells={saturation.openCells}
          selectedVertical={selectedVertical}
          showHeatmap={showHeatmap}
          showProspecting={showProspecting}
          dataVersion={version}
          resolution={saturation.resolution}
          onViewportChange={handleViewportChange}
          flyToTarget={flyToTarget}
        />
        {/* AS-T6 / AC-021: the floating top-right saturation panel — a SEPARATE
            surface; the left CRUD .site-panel below is untouched. */}
        <SaturationPanel
          selectedVertical={selectedVertical}
          showHeatmap={showHeatmap}
          showProspecting={showProspecting}
          coveredCount={saturation.coveredCount}
          openCount={saturation.openCount}
          capped={saturation.capped}
          computing={computing}
          announcement={announcement}
          onSelectVertical={handleSelectVertical}
          onToggleHeatmap={setShowHeatmap}
          onToggleProspecting={setShowProspecting}
          onJumpToOpen={handleJumpToOpen}
        />
        {/* A11Y-004: the customer forms/list panel is the primary content, so it
            is a <main> landmark (was an <aside>). The map remains the
            complementary surface. */}
        <main className="site-panel">
          <CustomerForm onChanged={() => void reload()} />
          <CustomerImport onChanged={() => void reload()} />
          <CustomerList
            onChanged={() => void reload()}
            reloadVersion={version}
            conflictsBySite={conflictsBySite}
            conflictsLoading={conflictsLoading}
          />
        </main>
      </div>
    </AuthGate>
  );
}
