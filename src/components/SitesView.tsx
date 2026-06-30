import { useEffect, useId, useState } from 'react';
import { supabase } from '../lib/supabaseClient';
import {
  updateSiteName,
  updateSiteAddress,
  updateSiteLocation,
  updateSiteRadius,
  isValidLatLng,
  verticalLabel,
  type SiteGeo,
} from '../lib/customers';
import { defaultGeocoder } from '../lib/geocoder';

/**
 * SitesView — the flat, full-width "Sites" data-management table.
 *
 * Unlike the map + CustomerList (which gate site visibility by the multi-select
 * vertical chooser), this table is DELIBERATELY NOT vertical-gated: it shows
 * EVERY site in the tenant so the operator can see and FIX incomplete rows —
 * above all the un-geocoded ones (null lat/lng) that keep the map from working.
 *
 * Reads use the `site_geo` view (RLS-auto-scoped to the tenant, no client
 * `where tenant_id`) joined client-side with `customer.name` for the Brand
 * column (`site_geo.vertical` is already the customer's vertical). Writes go
 * through the customers.ts seam (`updateSiteName` / `updateSiteAddress` /
 * `updateSiteLocation` / `updateSiteRadius`) and the `defaultGeocoder` seam —
 * never raw supabase/rpc. After any mutation `onChanged()` refreshes the lifted
 * map state (App) and bumps `reloadVersion`, which re-fetches this table so the
 * map reflects the fix on switch-back.
 *
 * A11y mirrors the W1/W2 patterns: a semantic <table> (thead/th scope="col"),
 * useId-derived labels with aria-label on every inline control, role="alert"
 * save errors, an aria-live bulk-geocode status, native inputs/buttons, and the
 * global :focus-visible outline.
 */

/** The locked per-site exclusivity-radius value set (mirrors CustomerList). */
const RADIUS_OPTIONS: ReadonlyArray<{ value: string; label: string }> = [
  { value: '', label: 'Off' },
  { value: '0.5', label: '0.5' },
  { value: '1', label: '1' },
  { value: '1.5', label: '1.5' },
  { value: '2', label: '2' },
  { value: '2.5', label: '2.5' },
  { value: '3', label: '3' },
];

interface Brand {
  id: string;
  name: string;
}

type LoadState =
  | { status: 'loading' }
  | { status: 'error'; message: string }
  | { status: 'ready'; sites: SiteGeo[]; brands: Map<string, string> };

function isLocated(s: SiteGeo): boolean {
  return s.lat != null && s.lng != null;
}

export function SitesView({
  onChanged,
  reloadVersion,
}: {
  onChanged: () => void;
  reloadVersion: number;
}) {
  const [state, setState] = useState<LoadState>({ status: 'loading' });
  const [onlyMissing, setOnlyMissing] = useState(false);
  const [bulkBusy, setBulkBusy] = useState(false);
  const [bulkStatus, setBulkStatus] = useState('');
  const onlyMissingId = useId();

  useEffect(() => {
    let cancelled = false;
    async function load() {
      const [sitesRes, customersRes] = await Promise.all([
        supabase.from('site_geo').select('*').order('name'),
        supabase.from('customer').select('id, name').order('name'),
      ]);
      if (cancelled) {
        return;
      }
      if (sitesRes.error) {
        setState({ status: 'error', message: sitesRes.error.message });
        return;
      }
      if (customersRes.error) {
        setState({ status: 'error', message: customersRes.error.message });
        return;
      }
      const brands = new Map<string, string>();
      for (const c of (customersRes.data ?? []) as Brand[]) {
        brands.set(c.id, c.name);
      }
      setState({
        status: 'ready',
        sites: (sitesRes.data ?? []) as SiteGeo[],
        brands,
      });
    }
    void load();
    return () => {
      cancelled = true;
    };
  }, [reloadVersion]);

  if (state.status === 'loading') {
    return (
      <section className="sites-view" aria-label="Sites">
        <h2>Sites</h2>
        <p>Loading sites…</p>
      </section>
    );
  }
  if (state.status === 'error') {
    return (
      <section className="sites-view" aria-label="Sites">
        <h2>Sites</h2>
        <p role="alert" className="form-error">
          Could not load sites: {state.message}
        </p>
      </section>
    );
  }

  const { sites, brands } = state;

  // Stable order: un-located sites first (the ones that need fixing), then by
  // brand, then by site name. The secondary keys keep the order deterministic
  // across reloads.
  const sorted = [...sites].sort((a, b) => {
    const al = isLocated(a) ? 1 : 0;
    const bl = isLocated(b) ? 1 : 0;
    if (al !== bl) {
      return al - bl;
    }
    const ab = (brands.get(a.customer_id) ?? '').localeCompare(
      brands.get(b.customer_id) ?? '',
    );
    if (ab !== 0) {
      return ab;
    }
    return a.name.localeCompare(b.name);
  });

  const missing = sites.filter((s) => !isLocated(s));
  const missingCount = missing.length;
  const rows = onlyMissing ? sorted.filter((s) => !isLocated(s)) : sorted;

  // Header "Geocode all missing (N)": batch-geocode every null-lat/lng site
  // through the geocoder seam in ONE call, then persist each resolved point.
  // Sites with no address can't be geocoded — they count toward the failed
  // tally so "geocoded X of N; Y still failed" stays honest.
  async function geocodeAllMissing() {
    setBulkBusy(true);
    setBulkStatus(`Geocoding ${missingCount} site${missingCount === 1 ? '' : 's'}…`);
    const addressed = missing.filter((s) => s.address && s.address.trim());
    let ok = 0;
    try {
      const results = await defaultGeocoder.geocodeDetailed(
        addressed.map((s) => s.address as string),
      );
      for (let i = 0; i < addressed.length; i++) {
        const r = results[i];
        if (r && r.point) {
          try {
            await updateSiteLocation(addressed[i].id, r.point);
            ok += 1;
          } catch {
            // A persistence failure leaves the site un-located; counted as failed.
          }
        }
      }
      const failed = missingCount - ok;
      setBulkStatus(
        `Geocoded ${ok} of ${missingCount}; ${failed} still failed.`,
      );
      onChanged();
    } catch (err) {
      setBulkStatus(
        `Bulk geocode failed: ${err instanceof Error ? err.message : 'unknown error'}.`,
      );
    } finally {
      setBulkBusy(false);
    }
  }

  return (
    <section className="sites-view" aria-label="Sites">
      <div className="sites-view__header">
        <h2>Sites</h2>
        <p>
          {sites.length} site{sites.length === 1 ? '' : 's'} in your tenant
          {missingCount > 0
            ? ` · ${missingCount} need${missingCount === 1 ? 's' : ''} location`
            : ' · all located'}
        </p>
        <div className="sites-view__toolbar">
          <span className="field-checkbox">
            <input
              id={onlyMissingId}
              type="checkbox"
              checked={onlyMissing}
              onChange={(e) => setOnlyMissing(e.target.checked)}
            />
            <label htmlFor={onlyMissingId}>Show only sites needing location</label>
          </span>
          <button
            type="button"
            className="btn-secondary"
            disabled={bulkBusy || missingCount === 0}
            onClick={() => void geocodeAllMissing()}
          >
            {bulkBusy
              ? 'Geocoding…'
              : `Geocode all missing (${missingCount})`}
          </button>
        </div>
        {/* A11Y-003: pre-seeded live region — present from first paint so the
            bulk-geocode progress/result is announced; only the content toggles. */}
        <p className="helper-text" aria-live="polite">
          {bulkStatus}
        </p>
      </div>

      {sites.length === 0 ? (
        <p>No sites yet. Add customers and sites from the Map view.</p>
      ) : (
        <div className="sites-table-wrap">
          <table className="sites-table">
            <caption className="sr-only">
              All sites in your tenant, editable inline. Un-located sites are
              listed first.
            </caption>
            <thead>
              <tr>
                <th scope="col">Brand</th>
                <th scope="col">Site name</th>
                <th scope="col">Address</th>
                <th scope="col">Vertical</th>
                <th scope="col">Lat</th>
                <th scope="col">Lng</th>
                <th scope="col">Radius (mi)</th>
                <th scope="col">Located?</th>
                <th scope="col">Actions</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((site) => (
                <SitesRow
                  // Composite key: remount the row when the PERSISTED values
                  // change (e.g. after a geocode), so the inline inputs re-seed
                  // from the fresh row rather than holding stale state.
                  key={`${site.id}:${site.lat}:${site.lng}:${site.name}:${site.address}`}
                  site={site}
                  brand={brands.get(site.customer_id) ?? '(unknown)'}
                  onChanged={onChanged}
                />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

function SitesRow({
  site,
  brand,
  onChanged,
}: {
  site: SiteGeo;
  brand: string;
  onChanged: () => void;
}) {
  const nameId = useId();
  const addrId = useId();
  const latId = useId();
  const lngId = useId();
  const radiusId = useId();

  const [name, setName] = useState(site.name);
  const [address, setAddress] = useState(site.address ?? '');
  const [lat, setLat] = useState(site.lat != null ? String(site.lat) : '');
  const [lng, setLng] = useState(site.lng != null ? String(site.lng) : '');
  const [radiusValue, setRadiusValue] = useState(
    site.exclusivity_radius_mi != null ? String(site.exclusivity_radius_mi) : '',
  );

  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);

  const located = isLocated(site);

  /** Run a mutation with shared busy/error/note plumbing + a reload on success. */
  async function run(
    fn: () => Promise<void>,
    okNote: string,
    failNote: string,
  ) {
    setBusy(true);
    setError(null);
    setNote(null);
    try {
      await fn();
      setNote(okNote);
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : failNote);
    } finally {
      setBusy(false);
    }
  }

  function saveName() {
    void run(
      () => updateSiteName(site.id, name),
      'Site name saved.',
      'Could not save name.',
    );
  }

  // Address save RE-GEOCODES the new address (updateSiteAddress); a failed
  // re-geocode clears the location and is surfaced so the row stays flagged.
  function saveAddress() {
    setBusy(true);
    setError(null);
    setNote(null);
    void (async () => {
      try {
        const outcome = await updateSiteAddress(site.id, address.trim());
        setNote(
          outcome.status === 'geocoded'
            ? 'Address saved and re-geocoded.'
            : `Address saved, but geocoding failed (${outcome.reason ?? 'unknown'}). Enter lat/lng manually.`,
        );
        onChanged();
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Could not save address.');
      } finally {
        setBusy(false);
      }
    })();
  }

  // Manual lat/lng override — the recovery path for an un-geocodable site.
  // Reject empty/whitespace BEFORE numeric coercion (Number('') === 0) and
  // range-check via isValidLatLng so blanks never persist as 0,0.
  function saveLocation() {
    if (lat.trim() === '' || lng.trim() === '') {
      setError('Enter both latitude and longitude.');
      setNote(null);
      return;
    }
    const latN = Number(lat);
    const lngN = Number(lng);
    if (!isValidLatLng(latN, lngN)) {
      setError(
        'Enter valid coordinates: latitude -90 to 90, longitude -180 to 180.',
      );
      setNote(null);
      return;
    }
    void run(
      () => updateSiteLocation(site.id, { lat: latN, lng: lngN }),
      'Location saved.',
      'Could not save location.',
    );
  }

  // Per-row Geocode: resolve the CURRENT stored address through the geocoder
  // seam and write the point via updateSiteLocation (the address is unchanged).
  function geocodeRow() {
    if (!site.address || !site.address.trim()) {
      setError('No address to geocode. Add an address or enter lat/lng.');
      setNote(null);
      return;
    }
    setBusy(true);
    setError(null);
    setNote(null);
    void (async () => {
      try {
        const [result] = await defaultGeocoder.geocodeDetailed([site.address as string]);
        if (result && result.point) {
          await updateSiteLocation(site.id, result.point);
          setNote('Geocoded.');
          onChanged();
        } else {
          setError(
            `Geocoding failed (${result?.reason ?? 'unknown'}). Enter lat/lng manually.`,
          );
        }
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Geocoding failed.');
      } finally {
        setBusy(false);
      }
    })();
  }

  // Radius writes immediately on change (mirrors CustomerList); revert on error.
  function onRadiusChange(next: string) {
    const prev = radiusValue;
    setRadiusValue(next);
    setBusy(true);
    setError(null);
    setNote(null);
    void (async () => {
      try {
        await updateSiteRadius(site.id, next === '' ? null : Number(next));
        onChanged();
      } catch (err) {
        setRadiusValue(prev);
        setError(err instanceof Error ? err.message : 'Could not save radius.');
      } finally {
        setBusy(false);
      }
    })();
  }

  return (
    <tr className={located ? undefined : 'sites-row--needs-location'}>
      <td>{brand}</td>
      <td>
        <input
          id={nameId}
          type="text"
          className="sites-input"
          aria-label={`Site name for ${site.name}`}
          value={name}
          disabled={busy}
          onChange={(e) => setName(e.target.value)}
        />
        <button
          type="button"
          className="btn-secondary sites-cell-btn"
          disabled={busy}
          onClick={saveName}
        >
          Save name
        </button>
      </td>
      <td>
        <input
          id={addrId}
          type="text"
          className="sites-input"
          aria-label={`Address for ${site.name}`}
          value={address}
          disabled={busy}
          onChange={(e) => setAddress(e.target.value)}
        />
        <button
          type="button"
          className="btn-secondary sites-cell-btn"
          disabled={busy}
          onClick={saveAddress}
        >
          Save &amp; geocode
        </button>
      </td>
      <td>{site.vertical ? verticalLabel(site.vertical) : '—'}</td>
      <td>
        <input
          id={latId}
          type="number"
          step="any"
          className="sites-input sites-input--num"
          aria-label={`Latitude for ${site.name}`}
          value={lat}
          disabled={busy}
          onChange={(e) => setLat(e.target.value)}
        />
      </td>
      <td>
        <input
          id={lngId}
          type="number"
          step="any"
          className="sites-input sites-input--num"
          aria-label={`Longitude for ${site.name}`}
          value={lng}
          disabled={busy}
          onChange={(e) => setLng(e.target.value)}
        />
        <button
          type="button"
          className="btn-secondary sites-cell-btn"
          disabled={busy}
          onClick={saveLocation}
        >
          Save lat/lng
        </button>
      </td>
      <td>
        <label htmlFor={radiusId} className="sr-only">
          Zone radius (mi) for {site.name}
        </label>
        <select
          id={radiusId}
          className="sites-input"
          value={radiusValue}
          disabled={busy}
          onChange={(e) => onRadiusChange(e.target.value)}
        >
          {RADIUS_OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </select>
      </td>
      <td>
        {located ? (
          <span className="geo-status geo-status--ok">
            <span className="geo-glyph" aria-hidden="true">
              ✓
            </span>
            Located
          </span>
        ) : (
          <span className="badge-needs-location">
            <span className="geo-glyph" aria-hidden="true">
              ⚠
            </span>
            Needs location
          </span>
        )}
      </td>
      <td>
        <button
          type="button"
          className="btn-secondary sites-cell-btn"
          disabled={busy}
          onClick={geocodeRow}
        >
          Geocode
        </button>
        {/* A11Y-003: pre-seeded live region for the per-row save status. */}
        <span className="helper-text" aria-live="polite">
          {note ?? ''}
        </span>
        {error && (
          <span role="alert" className="form-error sites-cell-error">
            {error}
          </span>
        )}
      </td>
    </tr>
  );
}
