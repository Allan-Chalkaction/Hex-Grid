import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

/**
 * SitesView + App-toggle tests (CG Sites-table). The project is node-only (no
 * jsdom/RTL — a logged deferral mirrored from MapDrawer.test.ts), so the new UI
 * is verified by a source-contract grep over SitesView.tsx / App.tsx / index.css
 * for the load-bearing a11y + wiring invariants:
 *   - the semantic <table> (thead / th scope="col") and the editable columns,
 *   - the NOT-vertical-gated read (no selectedVerticals filtering),
 *   - the customers.ts + geocoder seam usage (incl. the new updateSiteName),
 *   - per-row Geocode + the header "Geocode all missing (N)" batch wiring,
 *   - the a11y contract (useId, aria-label, role="alert", aria-live, native
 *     inputs/buttons, the "Needs location" badge + row highlight),
 *   - the App Map ⇄ Sites toggle and the conditional render that hides the map.
 * See the COMPLETION_REPORT RTL→source-contract flag.
 */

const sitesSrc = readFileSync(
  fileURLToPath(new URL('./SitesView.tsx', import.meta.url)),
  'utf8',
);
const appSrc = readFileSync(
  fileURLToPath(new URL('../App.tsx', import.meta.url)),
  'utf8',
);
const css = readFileSync(
  fileURLToPath(new URL('../index.css', import.meta.url)),
  'utf8',
);

describe('SitesView.tsx — semantic table', () => {
  it('renders a real <table> with a <thead> and scoped column headers', () => {
    expect(sitesSrc).toContain('<table');
    expect(sitesSrc).toContain('<thead>');
    expect(sitesSrc).toContain('<tbody>');
    expect(sitesSrc).toContain('scope="col"');
  });

  it('has the required columns', () => {
    for (const col of [
      'Brand',
      'Site name',
      'Address',
      'Vertical',
      'Lat',
      'Lng',
      'Radius (mi)',
      'Located?',
    ]) {
      expect(sitesSrc).toContain(`>${col}<`);
    }
  });
});

describe('SitesView.tsx — NOT vertical-gated', () => {
  it('does not filter the rows by the selected-verticals gate', () => {
    // The whole point of the Sites table is to show EVERY site (incl. ones with
    // no vertical) so incomplete rows can be fixed — it must not consume the
    // map's selectedVerticals gate.
    expect(sitesSrc).not.toContain('selectedVerticals');
  });

  it('reads every tenant site from the RLS-scoped site_geo view', () => {
    expect(sitesSrc).toContain("from('site_geo')");
    // Brand comes from a client-side join with customer.name.
    expect(sitesSrc).toContain("from('customer')");
  });
});

describe('SitesView.tsx — seam usage (reuses customers.ts + geocoder)', () => {
  it('imports the customers.ts helpers (adds only updateSiteName)', () => {
    expect(sitesSrc).toContain('updateSiteName');
    expect(sitesSrc).toContain('updateSiteAddress');
    expect(sitesSrc).toContain('updateSiteLocation');
    expect(sitesSrc).toContain('updateSiteRadius');
    expect(sitesSrc).toContain('isValidLatLng');
  });

  it('uses the defaultGeocoder seam (never supabase.functions directly)', () => {
    expect(sitesSrc).toContain('defaultGeocoder');
    expect(sitesSrc).toContain('geocodeDetailed');
    expect(sitesSrc).not.toContain('functions.invoke');
  });

  it('manual lat/lng override guards empty/whitespace before coercion', () => {
    // CR-002: Number('') === 0, so a blank must be rejected BEFORE numeric
    // coercion or it would silently persist as 0,0.
    expect(sitesSrc).toContain("lat.trim() === ''");
    expect(sitesSrc).toContain("lng.trim() === ''");
    expect(sitesSrc).toContain('isValidLatLng(');
  });
});

describe('SitesView.tsx — geocode actions', () => {
  it('has a per-row Geocode action', () => {
    expect(sitesSrc).toContain('geocodeRow');
    expect(sitesSrc).toContain('onClick={geocodeRow}');
  });

  it('has the header "Geocode all missing (N)" batch action', () => {
    expect(sitesSrc).toContain('geocodeAllMissing');
    expect(sitesSrc).toContain('Geocode all missing (');
    // The batch reports an aria-live progress/result.
    expect(sitesSrc).toContain('still failed');
  });
});

describe('SitesView.tsx — a11y contract', () => {
  it('uses useId + aria-label on inline controls', () => {
    expect(sitesSrc).toContain('useId');
    expect(sitesSrc).toContain('aria-label=');
  });

  it('announces save errors via role="alert" and status via aria-live', () => {
    expect(sitesSrc).toContain('role="alert"');
    expect(sitesSrc).toContain('aria-live="polite"');
  });

  it('uses native inputs/buttons (no role-reinvented widgets)', () => {
    expect(sitesSrc).toContain('type="text"');
    expect(sitesSrc).toContain('type="number"');
    expect(sitesSrc).toContain('type="button"');
    expect(sitesSrc).not.toContain('role="button"');
  });

  it('flags un-located rows with a "Needs location" badge + row highlight', () => {
    expect(sitesSrc).toContain('Needs location');
    expect(sitesSrc).toContain('badge-needs-location');
    expect(sitesSrc).toContain('sites-row--needs-location');
  });

  it('bumps the shared reload version after a save (onChanged)', () => {
    expect(sitesSrc).toContain('onChanged()');
    expect(sitesSrc).toContain('reloadVersion');
  });
});

describe('App.tsx — Map ⇄ Sites toggle', () => {
  it('owns a view state and a useId-labelled toggle group', () => {
    expect(appSrc).toContain("useState<'map' | 'sites'>('map')");
    expect(appSrc).toContain('role="group"');
    expect(appSrc).toContain('aria-labelledby=');
    expect(appSrc).toContain('aria-pressed={view === ');
  });

  it('passes the toggle into the header slot and conditionally renders', () => {
    expect(appSrc).toContain('headerSlot={viewToggle}');
    expect(appSrc).toContain("view === 'map'");
    expect(appSrc).toContain('<SitesView');
    // The map + drawer only mount in map view (Sites view hides them).
    expect(appSrc).toContain('<MapShell');
    expect(appSrc).toContain('<MapDrawer');
  });
});

describe('index.css — Sites view styling', () => {
  it('styles the view toggle, table, badge, and needs-location highlight', () => {
    expect(css).toContain('.view-toggle');
    expect(css).toContain('.sites-table');
    expect(css).toContain('.badge-needs-location');
    expect(css).toContain('.sites-row--needs-location');
    expect(css).toContain('.sr-only');
  });

  it("aria-pressed marks the active view (not color alone)", () => {
    expect(css).toContain("[aria-pressed='true']");
  });
});
