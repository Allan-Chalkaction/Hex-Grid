import { useEffect, useId, useRef, useState } from 'react';
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
        {/* A11Y-002 (WCAG 4.1.3): the loading message is a live status so the
            transition out of "loading" is announced. */}
        <p role="status">Loading sites…</p>
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
      ) : onlyMissing && rows.length === 0 ? (
        // L2: the "only sites needing location" filter is on but every site is
        // located — say so instead of rendering an empty table body.
        <p>No sites need a location.</p>
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
                  // CR-001: key on the STABLE site id only — never the mutable
                  // values. A composite value key remounts the row on any single
                  // save, discarding the operator's unsaved edits in the row's
                  // OTHER fields. The row now seeds its inputs once and reconciles
                  // each field from fresh props via a dirty-aware effect (see
                  // SitesRow), so a geocode still re-seeds lat/lng without
                  // clobbering an in-progress address edit.
                  key={site.id}
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

  // Inputs seed ONCE from the row (the row keys on site.id only, so it never
  // remounts on a value change). The persisted values below + the reconcile
  // effect keep each field in sync with server changes WITHOUT clobbering the
  // operator's unsaved edits in sibling fields (CR-001).
  const persistedName = site.name;
  const persistedAddress = site.address ?? '';
  const persistedLat = site.lat != null ? String(site.lat) : '';
  const persistedLng = site.lng != null ? String(site.lng) : '';

  const [name, setName] = useState(persistedName);
  const [address, setAddress] = useState(persistedAddress);
  const [lat, setLat] = useState(persistedLat);
  const [lng, setLng] = useState(persistedLng);
  const [radiusValue, setRadiusValue] = useState(
    site.exclusivity_radius_mi != null ? String(site.exclusivity_radius_mi) : '',
  );

  // CR-001: dirty-aware reconcile. When a field's OWN persisted value changes
  // (e.g. a geocode rewrote lat/lng, or a sibling save reloaded the row), re-seed
  // that field's input ONLY if it isn't dirty — i.e. the input still holds the
  // value we last saw persisted. A field the operator has typed into (dirty) is
  // left untouched, so saving one field never drops an in-progress edit in
  // another. Each field is tracked independently against the last-seen snapshot.
  const seen = useRef({
    name: persistedName,
    address: persistedAddress,
    lat: persistedLat,
    lng: persistedLng,
  });
  useEffect(() => {
    const prev = seen.current;
    if (persistedName !== prev.name) {
      const old = prev.name;
      setName((cur) => (cur === old ? persistedName : cur));
    }
    if (persistedAddress !== prev.address) {
      const old = prev.address;
      setAddress((cur) => (cur === old ? persistedAddress : cur));
    }
    if (persistedLat !== prev.lat) {
      const old = prev.lat;
      setLat((cur) => (cur === old ? persistedLat : cur));
    }
    if (persistedLng !== prev.lng) {
      const old = prev.lng;
      setLng((cur) => (cur === old ? persistedLng : cur));
    }
    seen.current = {
      name: persistedName,
      address: persistedAddress,
      lat: persistedLat,
      lng: persistedLng,
    };
  }, [persistedName, persistedAddress, persistedLat, persistedLng]);

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
          aria-label={`Save name for ${site.name}`}
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
          aria-label={`Save & geocode for ${site.name}`}
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
          aria-label={`Save lat/lng for ${site.name}`}
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
          aria-label={`Geocode ${site.name}`}
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
