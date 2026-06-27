import { AuthGate } from './components/AuthGate';
import { MapShell } from './components/MapShell';
import { SiteList } from './components/SiteList';

/**
 * App composition (AC-004 / AC-005).
 *
 * `SiteList` is rendered behind the `AuthGate` — only an authenticated user sees
 * the tenant-scoped site fetch fire. The `MapShell` fills the background; the
 * site panel overlays it.
 */
export function App() {
  return (
    <AuthGate>
      <div className="app-shell">
        <MapShell />
        <aside className="site-panel">
          <SiteList />
        </aside>
      </div>
    </AuthGate>
  );
}
