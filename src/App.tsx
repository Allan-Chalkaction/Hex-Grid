import { useCallback, useEffect, useMemo, useState } from 'react';
import { AuthGate } from './components/AuthGate';
import { MapShell } from './components/MapShell';
import { CustomerForm } from './components/CustomerForm';
import { CustomerImport } from './components/CustomerImport';
import { CustomerList } from './components/CustomerList';
import { supabase } from './lib/supabaseClient';
import type { SiteGeo } from './lib/customers';
import { findSiteConflicts, type Conflict } from './lib/conflicts';

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
        <MapShell sites={sites} conflictIds={conflictIds} />
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
