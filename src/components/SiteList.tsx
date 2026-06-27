import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabaseClient';

interface Site {
  id: string;
  name: string;
}

type LoadState =
  | { status: 'loading' }
  | { status: 'error'; message: string }
  | { status: 'ready'; sites: Site[] };

/**
 * Tenant-scoped site list (AC-005).
 *
 * On mount it actually calls `supabase.from('site').select('*')`. RLS auto-scopes
 * the result to the authenticated user's tenant in the database — the client adds
 * no `where tenant_id =` clause. Empty in W1 (no site write path yet), but the
 * read path is end-to-end real, not stubbed. The count is rendered as plain text
 * so it is screen-reader readable (a11y).
 */
export function SiteList() {
  const [state, setState] = useState<LoadState>({ status: 'loading' });

  useEffect(() => {
    let cancelled = false;

    async function load() {
      const { data, error } = await supabase
        .from('site')
        .select('id, name')
        .order('name');

      if (cancelled) {
        return;
      }
      if (error) {
        setState({ status: 'error', message: error.message });
        return;
      }
      setState({ status: 'ready', sites: (data ?? []) as Site[] });
    }

    void load();
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <section aria-label="Sites" className="site-list">
      <h2>Sites</h2>
      {state.status === 'loading' && <p>Loading sites…</p>}
      {state.status === 'error' && (
        <p role="alert">Could not load sites: {state.message}</p>
      )}
      {state.status === 'ready' && (
        <>
          <p>
            {state.sites.length} site{state.sites.length === 1 ? '' : 's'} in
            your tenant
          </p>
          {state.sites.length === 0 ? (
            <p>No sites yet.</p>
          ) : (
            <ul>
              {state.sites.map((site) => (
                <li key={site.id}>{site.name}</li>
              ))}
            </ul>
          )}
        </>
      )}
    </section>
  );
}
