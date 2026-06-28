import { useEffect, useId, useRef, useState } from 'react';
import { supabase } from '../lib/supabaseClient';
import {
  updateSiteAddress,
  updateSiteLocation,
  updateCustomerVertical,
  deleteCustomer,
  isValidLatLng,
  verticalLabel,
  VERTICAL_OPTIONS,
  type SiteGeo,
} from '../lib/customers';

/**
 * CRUD list (AC-015 / AC-020) — supersedes the read-only W1 site list.
 *
 * Lists customers with their sites via an RLS-auto-scoped read (no client
 * `where tenant_id`, like the W1 read pattern). Reads use the `site_geo` view; writes
 * target the `site` / `customer` BASE tables. Supports edit-site-address
 * (re-geocode → pin moves), move-site (update location → pin moves), and
 * delete-customer (cascades its sites; a confirm states "deletes N sites").
 * After any mutation `onChanged()` refreshes the lifted map state (AC-010) and
 * bumps `reloadVersion`, which re-fetches this list.
 *
 * A11y mirrors the W1 AuthGate read patterns: useId label association, real
 * <label>/<button>, role="alert" errors, native focus order.
 */

interface Customer {
  id: string;
  name: string;
  vertical: string | null;
}

type LoadState =
  | { status: 'loading' }
  | { status: 'error'; message: string }
  | { status: 'ready'; customers: Customer[]; sites: SiteGeo[] };

export function CustomerList({
  onChanged,
  reloadVersion,
}: {
  onChanged: () => void;
  reloadVersion: number;
}) {
  const [state, setState] = useState<LoadState>({ status: 'loading' });

  useEffect(() => {
    let cancelled = false;
    async function load() {
      const [customersRes, sitesRes] = await Promise.all([
        supabase.from('customer').select('id, name, vertical').order('name'),
        supabase.from('site_geo').select('*').order('name'),
      ]);
      if (cancelled) {
        return;
      }
      if (customersRes.error) {
        setState({ status: 'error', message: customersRes.error.message });
        return;
      }
      if (sitesRes.error) {
        setState({ status: 'error', message: sitesRes.error.message });
        return;
      }
      setState({
        status: 'ready',
        customers: (customersRes.data ?? []) as Customer[],
        sites: (sitesRes.data ?? []) as SiteGeo[],
      });
    }
    void load();
    return () => {
      cancelled = true;
    };
  }, [reloadVersion]);

  if (state.status === 'loading') {
    return (
      <section className="panel-section" aria-label="Customers">
        <h2>Customers</h2>
        <p>Loading customers…</p>
      </section>
    );
  }
  if (state.status === 'error') {
    return (
      <section className="panel-section" aria-label="Customers">
        <h2>Customers</h2>
        <p role="alert">Could not load customers: {state.message}</p>
      </section>
    );
  }

  const sitesByCustomer = new Map<string, SiteGeo[]>();
  for (const site of state.sites) {
    const list = sitesByCustomer.get(site.customer_id) ?? [];
    list.push(site);
    sitesByCustomer.set(site.customer_id, list);
  }

  return (
    <section className="panel-section customer-list" aria-label="Customers">
      <h2>Customers</h2>
      <p>
        {state.customers.length} customer
        {state.customers.length === 1 ? '' : 's'} in your tenant
      </p>
      {state.customers.length === 0 ? (
        <p>No customers yet.</p>
      ) : (
        <ul>
          {state.customers.map((customer) => {
            const sites = sitesByCustomer.get(customer.id) ?? [];
            return (
              <li key={customer.id} className="customer-item">
                <CustomerRow
                  customer={customer}
                  sites={sites}
                  onChanged={onChanged}
                />
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

function CustomerRow({
  customer,
  sites,
  onChanged,
}: {
  customer: Customer;
  sites: SiteGeo[];
  onChanged: () => void;
}) {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const dialogRef = useRef<HTMLDialogElement>(null);
  const deleteBtnRef = useRef<HTMLButtonElement>(null);

  // EX-T3 / AC-019: the "Edit vertical" reveal — mirrors the SiteRow
  // edit-address pattern (A11Y-001 focus-on-reveal). View shows the current
  // vertical; editing reveals a controlled <select> + Save/Cancel.
  const verticalId = useId();
  const [vEditing, setVEditing] = useState(false);
  const [vValue, setVValue] = useState(customer.vertical ?? '');
  const [vBusy, setVBusy] = useState(false);
  const [vError, setVError] = useState<string | null>(null);
  const verticalSelectRef = useRef<HTMLSelectElement>(null);

  useEffect(() => {
    if (vEditing) {
      verticalSelectRef.current?.focus();
    }
  }, [vEditing]);

  async function saveVertical() {
    setVBusy(true);
    setVError(null);
    try {
      await updateCustomerVertical(customer.id, vValue || null);
      setVEditing(false);
      onChanged();
    } catch (err) {
      setVError(err instanceof Error ? err.message : 'Could not save vertical.');
    } finally {
      setVBusy(false);
    }
  }

  const siteCount = `${sites.length} site${sites.length === 1 ? '' : 's'}`;

  // A11Y-002 / M-6: a native <dialog> confirm replaces window.confirm — real
  // buttons, ESC cancels, focus returns to the trigger on close.
  function requestDelete() {
    setError(null);
    dialogRef.current?.showModal();
  }

  async function confirmDelete() {
    dialogRef.current?.close();
    setBusy(true);
    setError(null);
    try {
      await deleteCustomer(customer.id);
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Delete failed.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <div className="row-actions">
        <strong>{customer.name}</strong>
        <button
          ref={deleteBtnRef}
          type="button"
          className="btn-danger"
          disabled={busy}
          onClick={requestDelete}
        >
          Delete customer ({siteCount})
        </button>
      </div>

      <dialog
        ref={dialogRef}
        className="confirm-dialog"
        onClose={() => deleteBtnRef.current?.focus()}
      >
        <p>
          Delete &ldquo;{customer.name}&rdquo;? This deletes {siteCount}.
        </p>
        <div className="row-actions">
          <button
            type="button"
            className="btn-danger"
            onClick={() => void confirmDelete()}
          >
            Delete customer
          </button>
          <button
            type="button"
            className="btn-secondary"
            onClick={() => dialogRef.current?.close()}
          >
            Cancel
          </button>
        </div>
      </dialog>
      {error && (
        <p role="alert" className="form-error">
          {error}
        </p>
      )}

      {/* EX-T3 / AC-019: customer vertical — view + "Edit vertical" reveal. */}
      {!vEditing ? (
        <div className="row-actions">
          {customer.vertical ? (
            <span className="helper-text">
              Vertical: {verticalLabel(customer.vertical)}
            </span>
          ) : (
            <span className="helper-text">
              No vertical set. Set a vertical to enable conflict detection.
            </span>
          )}
          <button
            type="button"
            className="btn-secondary"
            onClick={() => {
              setVValue(customer.vertical ?? '');
              setVError(null);
              setVEditing(true);
            }}
          >
            Edit vertical
          </button>
        </div>
      ) : (
        <div className="field-inline">
          <span className="field">
            <label htmlFor={verticalId}>Vertical</label>
            <select
              ref={verticalSelectRef}
              id={verticalId}
              value={vValue}
              onChange={(e) => setVValue(e.target.value)}
            >
              <option value="">Select vertical…</option>
              {VERTICAL_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </span>
          <button
            type="button"
            className="btn-secondary"
            disabled={vBusy}
            onClick={() => void saveVertical()}
          >
            {vBusy ? 'Saving…' : 'Save'}
          </button>
          <button
            type="button"
            className="btn-secondary"
            onClick={() => setVEditing(false)}
          >
            Cancel
          </button>
        </div>
      )}
      {vBusy && (
        <p className="helper-text" aria-live="polite">
          Saving vertical…
        </p>
      )}
      {vError && (
        <p role="alert" className="form-error">
          {vError}
        </p>
      )}

      {sites.length === 0 ? (
        <p className="helper-text">No sites.</p>
      ) : (
        <ul>
          {sites.map((site) => (
            <li key={site.id}>
              <SiteRow site={site} onChanged={onChanged} />
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

function SiteRow({
  site,
  onChanged,
}: {
  site: SiteGeo;
  onChanged: () => void;
}) {
  const addrId = useId();
  const latId = useId();
  const lngId = useId();
  const [mode, setMode] = useState<'view' | 'edit-address' | 'move'>('view');
  const [address, setAddress] = useState(site.address ?? '');
  const [lat, setLat] = useState(site.lat != null ? String(site.lat) : '');
  const [lng, setLng] = useState(site.lng != null ? String(site.lng) : '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState<string | null>(null);
  const firstFieldRef = useRef<HTMLInputElement>(null);

  // A11Y-001: move focus to the first revealed input when entering an edit mode.
  useEffect(() => {
    if (mode !== 'view') {
      firstFieldRef.current?.focus();
    }
  }, [mode]);

  const located = site.lat != null && site.lng != null;

  async function saveAddress() {
    setBusy(true);
    setError(null);
    setNote(null);
    try {
      const outcome = await updateSiteAddress(site.id, address.trim());
      setNote(
        outcome.status === 'geocoded'
          ? 'Address updated and re-geocoded.'
          : `Address updated, but geocoding failed (${outcome.reason ?? 'unknown'}).`,
      );
      setMode('view');
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Update failed.');
    } finally {
      setBusy(false);
    }
  }

  async function saveMove() {
    // CR-002: reject empty/whitespace BEFORE numeric coercion (Number('') is 0)
    // and range-check before persisting, so blanks never save as 0,0.
    if (lat.trim() === '' || lng.trim() === '') {
      setError('Enter both latitude and longitude.');
      return;
    }
    const latN = Number(lat);
    const lngN = Number(lng);
    if (!isValidLatLng(latN, lngN)) {
      setError(
        'Enter valid coordinates: latitude -90 to 90, longitude -180 to 180.',
      );
      return;
    }
    setBusy(true);
    setError(null);
    setNote(null);
    try {
      await updateSiteLocation(site.id, { lat: latN, lng: lngN });
      setNote('Site moved.');
      setMode('view');
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Move failed.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="site-item">
      <span className="site-name">{site.name}</span>
      <span>{site.address ?? '(no address)'}</span>
      <span
        className={
          located ? 'geo-status geo-status--ok' : 'geo-status geo-status--failed'
        }
      >
        <span className="geo-glyph" aria-hidden="true">
          {located ? '✓' : '⚠'}
        </span>
        {located ? 'Located' : 'No location'}
      </span>

      {mode === 'view' && (
        <span className="row-actions">
          <button
            type="button"
            className="btn-secondary"
            onClick={() => setMode('edit-address')}
          >
            Edit address
          </button>
          <button
            type="button"
            className="btn-secondary"
            onClick={() => setMode('move')}
          >
            Move
          </button>
        </span>
      )}

      {mode === 'edit-address' && (
        <span className="field-inline">
          <span className="field">
            <label htmlFor={addrId}>New address</label>
            <input
              ref={firstFieldRef}
              id={addrId}
              type="text"
              value={address}
              onChange={(e) => setAddress(e.target.value)}
            />
          </span>
          <button
            type="button"
            className="btn-secondary"
            disabled={busy}
            onClick={() => void saveAddress()}
          >
            {busy ? 'Saving…' : 'Save address'}
          </button>
          <button
            type="button"
            className="btn-secondary"
            onClick={() => setMode('view')}
          >
            Cancel
          </button>
        </span>
      )}

      {mode === 'move' && (
        <span className="field-inline">
          <span className="field">
            <label htmlFor={latId}>Latitude</label>
            <input
              ref={firstFieldRef}
              id={latId}
              type="number"
              step="any"
              value={lat}
              onChange={(e) => setLat(e.target.value)}
            />
          </span>
          <span className="field">
            <label htmlFor={lngId}>Longitude</label>
            <input
              id={lngId}
              type="number"
              step="any"
              value={lng}
              onChange={(e) => setLng(e.target.value)}
            />
          </span>
          <button
            type="button"
            className="btn-secondary"
            disabled={busy}
            onClick={() => void saveMove()}
          >
            {busy ? 'Saving…' : 'Save location'}
          </button>
          <button
            type="button"
            className="btn-secondary"
            onClick={() => setMode('view')}
          >
            Cancel
          </button>
        </span>
      )}

      {note && (
        <span className="helper-text" aria-live="polite">
          {note}
        </span>
      )}
      {error && (
        <span role="alert" className="form-error">
          {error}
        </span>
      )}
    </div>
  );
}
