import { useCallback, useEffect, useState } from 'react';
import { AuthGate } from './components/AuthGate';
import { MapShell } from './components/MapShell';
import { CustomerForm } from './components/CustomerForm';
import { CustomerImport } from './components/CustomerImport';
import { CustomerList } from './components/CustomerList';
import { supabase } from './lib/supabaseClient';
import type { SiteGeo } from './lib/customers';

/**
 * App composition (AC-010 / AC-011 / AC-015 / AC-020).
 *
 * App is the OWNER of the lifted `sites` state (the reactive map-data seam,
 * AC-010): it loads `site_geo` (RLS-auto-scoped) and passes `sites` to
 * `MapShell`, which holds its deck.gl overlay in a ref and re-renders the pin
 * layer on every change. `reload` re-fetches the sites AND bumps a version that
 * re-fetches `CustomerList`, so any add/edit/move/delete reflects on the map and
 * in the list without a page reload.
 */
export function App() {
  const [sites, setSites] = useState<SiteGeo[]>([]);
  const [version, setVersion] = useState(0);

  const reload = useCallback(async () => {
    const { data } = await supabase.from('site_geo').select('*').order('name');
    setSites((data ?? []) as SiteGeo[]);
    setVersion((v) => v + 1);
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
      setSites((data ?? []) as SiteGeo[]);
      setVersion((v) => v + 1);
    }
    void load();
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <AuthGate>
      <div className="app-shell">
        <MapShell sites={sites} />
        <aside className="site-panel">
          <CustomerForm onChanged={() => void reload()} />
          <CustomerImport onChanged={() => void reload()} />
          <CustomerList
            onChanged={() => void reload()}
            reloadVersion={version}
          />
        </aside>
      </div>
    </AuthGate>
  );
}
