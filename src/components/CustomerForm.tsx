import { useId, useRef, useState } from 'react';
import {
  createCustomerWithSites,
  updateSiteLocation,
  isValidLatLng,
  verticalLabel,
  VERTICAL_OPTIONS,
  type SiteOutcome,
} from '../lib/customers';
import { findConflicts, type Conflict } from '../lib/conflicts';
import {
  defaultGeocoder,
  type GeocodeFailureReason,
} from '../lib/geocoder';

/** A prospective add-site grouped with the conflicts it would create. */
interface ConflictGroup {
  siteLabel: string;
  conflicts: Conflict[];
}

/**
 * Manual-add UI (AC-011 / AC-012).
 *
 * A SINGLE combined surface: customer brand fields (name + a vertical attribute)
 * plus a repeatable list of site rows requiring >= 1 site (submit is blocked
 * with 0 sites). On submit it calls `createCustomerWithSites` (CG-T4) to upsert
 * the customer, geocode each site, and persist via the place_site RPC; on
 * success `onChanged()` refreshes the lifted map state so the new pins appear
 * (AC-010 reactive seam).
 *
 * Per-site geocode status is shown DISTINCTLY (pending / geocoded / failed),
 * never by color alone (word + glyph + color, screen-reader readable). A failed
 * site is persisted UN-geocoded and flagged; each failure class surfaces its
 * specific recovery path. A11y mirrors the W1 AuthGate pattern (useId, real
 * <label>/<button>, role="alert").
 */

interface SiteRow {
  /** Stable per-row id used as the React key (CR-006), not the array index. */
  id: string;
  name: string;
  address: string;
}

let siteRowSeq = 0;
function newSiteRow(): SiteRow {
  siteRowSeq += 1;
  return { id: `site-row-${siteRowSeq}`, name: '', address: '' };
}

/** Maps a failure class to its specific recovery affordance (AC-012). */
function recoveryKind(
  reason: GeocodeFailureReason | null,
): 'retry' | 'backoff' | 'manual' {
  switch (reason) {
    case 'network-timeout':
      return 'retry';
    case 'rate-limit':
      return 'backoff';
    case 'no-match':
    case 'ambiguous':
    case 'invalid':
    default:
      return 'manual';
  }
}

function reasonLabel(reason: GeocodeFailureReason | null): string {
  switch (reason) {
    case 'no-match':
      return 'No match found';
    case 'ambiguous':
      return 'Address was ambiguous';
    case 'network-timeout':
      return 'Network timed out';
    case 'rate-limit':
      return 'Rate limited (429)';
    case 'invalid':
      return 'Address was invalid';
    default:
      return 'Geocoding failed';
  }
}

export function CustomerForm({ onChanged }: { onChanged: () => void }) {
  const nameId = useId();
  const verticalId = useId();
  const selfConflictId = useId();
  const conflictHeadingId = useId();

  const [customerName, setCustomerName] = useState('');
  const [vertical, setVertical] = useState('');
  // EX-T7 / CR-001: per-customer exclusivity scope. Default unchecked (false) =
  // competitor-only (a brand does NOT conflict with its own sites).
  const [selfConflict, setSelfConflict] = useState(false);
  const [rows, setRows] = useState<SiteRow[]>([newSiteRow()]);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [outcomes, setOutcomes] = useState<SiteOutcome[] | null>(null);

  // EX-T6 / AC-016/AC-020: warn-with-confirm conflict dialog on add. `checking`
  // drives the in-flight trigger ("Checking exclusivity…"); `pendingGroups` holds
  // the consolidated conflicts; `pendingFilled` is the rows to persist on "Add
  // anyway". `addNote` reports a cancelled add. Reuses the W2 A11Y-002 native
  // <dialog> pattern (showModal, real buttons, ESC cancels, onClose refocus).
  const [checking, setChecking] = useState(false);
  const [pendingGroups, setPendingGroups] = useState<ConflictGroup[]>([]);
  const [pendingFilled, setPendingFilled] = useState<SiteRow[]>([]);
  const [addNote, setAddNote] = useState<string | null>(null);
  const conflictDialogRef = useRef<HTMLDialogElement>(null);
  const submitBtnRef = useRef<HTMLButtonElement>(null);
  const cancelConflictRef = useRef<HTMLButtonElement>(null);

  function updateRow(i: number, patch: Partial<SiteRow>) {
    setRows((prev) => prev.map((r, idx) => (idx === i ? { ...r, ...patch } : r)));
  }

  function addRow() {
    setRows((prev) => [...prev, newSiteRow()]);
  }

  function removeRow(i: number) {
    setRows((prev) =>
      prev.length === 1 ? prev : prev.filter((_r, idx) => idx !== i),
    );
  }

  /** Persist the customer + sites (the W2 path). Re-geocodes via the cache-first
   *  seam (a hit after the conflict-preview geocode). AC-024: always persists. */
  async function doPersist(filled: SiteRow[]) {
    setSubmitting(true);
    setError(null);
    try {
      const result = await createCustomerWithSites({
        customerName: customerName.trim(),
        // EX-T3 / AC-019: the vertical is written to the customer.vertical COLUMN
        // (the conflict key), NOT to attributes. Empty option ⇒ null.
        vertical: vertical || null,
        // EX-T7 / CR-001: per-customer exclusivity scope.
        selfConflict,
        sites: filled.map((r) => ({
          name: r.name.trim() || undefined,
          address: r.address.trim(),
        })),
      });
      setOutcomes(result.sites);
      // Reset the site rows for the next add; keep the brand fields.
      setRows([newSiteRow()]);
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not add customer.');
    } finally {
      setSubmitting(false);
    }
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setOutcomes(null);
    setAddNote(null);

    const filled = rows.filter((r) => r.address.trim().length > 0);
    if (!customerName.trim()) {
      setError('Enter a customer name.');
      return;
    }
    if (filled.length === 0) {
      setError('Add at least one site with an address.');
      return;
    }

    // EX-T6 / AC-016: BEFORE persisting, geocode the prospective sites and check
    // each resolved point for same-vertical conflicts (a new site claims no zone
    // yet ⇒ radius null; it still conflicts if it lands in a neighbor's zone). A
    // null vertical ⇒ findConflicts returns empty ⇒ no dialog. The persist path
    // re-geocodes through the cache-first seam (a hit), so points agree.
    setChecking(true);
    try {
      const geocoded = await defaultGeocoder.geocodeDetailed(
        filled.map((r) => r.address.trim()),
      );
      const groups: ConflictGroup[] = [];
      for (let i = 0; i < filled.length; i++) {
        const pt = geocoded[i].point;
        if (!pt) {
          continue; // un-geocoded site can't be checked; persisted + flagged.
        }
        const conflicts = await findConflicts(
          { lng: pt.lng, lat: pt.lat },
          null,
          vertical || null,
          null,
          // EX-T7 / CR-001: a brand-new-customer add has no existing same-customer
          // sites, so pass null (behaves as cross-customer — correct).
          null,
        );
        if (conflicts.length > 0) {
          groups.push({
            siteLabel: filled[i].name.trim() || filled[i].address.trim(),
            conflicts,
          });
        }
      }

      if (groups.length > 0) {
        // Conflicts → ONE consolidated warn dialog; the user decides (AC-024).
        setPendingGroups(groups);
        setPendingFilled(filled);
        setChecking(false);
        conflictDialogRef.current?.showModal();
        // Default focus on Cancel (the safe choice) so a reflexive Enter never
        // silently overrides a conflict.
        cancelConflictRef.current?.focus();
        return;
      }

      // No conflicts → persist.
      setChecking(false);
      await doPersist(filled);
    } catch (err) {
      setChecking(false);
      setError(
        err instanceof Error ? err.message : 'Could not check exclusivity.',
      );
    }
  }

  // "Add anyway" — the non-blocking override: persist despite the conflicts.
  async function confirmAdd() {
    conflictDialogRef.current?.close();
    await doPersist(pendingFilled);
  }

  // "Cancel" — abort the add; nothing persists.
  function cancelAdd() {
    conflictDialogRef.current?.close();
    setAddNote('Add cancelled — conflict not overridden.');
  }

  return (
    <section className="panel-section" aria-label="Add customer">
      <h2>Add customer</h2>
      <form onSubmit={handleSubmit} noValidate>
        <div className="field">
          <label htmlFor={nameId}>Customer name</label>
          <input
            id={nameId}
            type="text"
            required
            value={customerName}
            onChange={(e) => setCustomerName(e.target.value)}
          />
        </div>
        <div className="field">
          <label htmlFor={verticalId}>Vertical</label>
          {/* EX-T3 / AC-019: a controlled native <select> (NOT free text) — string
              equality on the token is the conflict key. Empty option ⇒ null. */}
          <select
            id={verticalId}
            value={vertical}
            onChange={(e) => setVertical(e.target.value)}
          >
            <option value="">Select vertical…</option>
            {VERTICAL_OPTIONS.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </select>
        </div>

        {/* EX-T7 / CR-001: per-customer exclusivity scope. Default unchecked =
            competitor-only (a brand does NOT conflict with its own sites). */}
        <div className="field-checkbox">
          <input
            id={selfConflictId}
            type="checkbox"
            checked={selfConflict}
            onChange={(e) => setSelfConflict(e.target.checked)}
          />
          <label htmlFor={selfConflictId}>
            Also protect this brand’s own sites from each other
          </label>
        </div>

        <fieldset>
          <legend>Sites (at least one required)</legend>
          <div className="site-rows">
            {rows.map((row, i) => (
              <SiteRowFields
                key={row.id}
                index={i}
                row={row}
                canRemove={rows.length > 1}
                onChange={(patch) => updateRow(i, patch)}
                onRemove={() => removeRow(i)}
              />
            ))}
          </div>
          <button type="button" className="btn-secondary" onClick={addRow}>
            Add another site
          </button>
        </fieldset>

        {error && (
          <p role="alert" aria-live="assertive" className="form-error">
            {error}
          </p>
        )}

        <button
          ref={submitBtnRef}
          type="submit"
          disabled={submitting || checking}
        >
          {checking
            ? 'Checking exclusivity…'
            : submitting
              ? 'Adding & geocoding…'
              : 'Add customer'}
        </button>
        {/* A11Y-003: pre-seeded live region — rendered unconditionally so screen
            readers observe it from first paint; only the content toggles. */}
        <p className="helper-text" aria-live="polite">
          {addNote ?? ''}
        </p>
      </form>

      {/* EX-T6 / AC-016/AC-020/AC-023: warn-with-confirm conflict dialog on add.
          Reuses the W2 A11Y-002 native <dialog> (showModal, real buttons, ESC
          cancels, onClose refocuses the trigger). Default focus on Cancel. */}
      <dialog
        ref={conflictDialogRef}
        className="confirm-dialog"
        aria-labelledby={conflictHeadingId}
        onClose={() => submitBtnRef.current?.focus()}
      >
        <h2 id={conflictHeadingId}>Exclusivity conflict</h2>
        <p>
          Adding this customer falls within the exclusivity zone of same-vertical
          site(s):
        </p>
        {pendingGroups.map((g) => (
          <div key={g.siteLabel}>
            {pendingGroups.length > 1 && (
              <p className="helper-text">{g.siteLabel}:</p>
            )}
            <ul className="conflict-list">
              {g.conflicts.map((c) => (
                <li key={c.site_id}>
                  {c.customer_name} — {c.site_name} ·{' '}
                  {Number(c.distance_mi).toFixed(1)} mi · {verticalLabel(vertical)}
                </li>
              ))}
            </ul>
          </div>
        ))}
        <div className="row-actions">
          <button
            type="button"
            className="btn-danger"
            onClick={() => void confirmAdd()}
          >
            Add anyway
          </button>
          <button
            ref={cancelConflictRef}
            type="button"
            className="btn-secondary"
            onClick={cancelAdd}
          >
            Cancel
          </button>
        </div>
      </dialog>

      {/* A11Y-003: the live regions are rendered unconditionally so screen
          readers observe them from first paint; only their CONTENT toggles. */}
      <p className="geo-status geo-status--pending" aria-live="polite">
        {submitting && (
          <>
            <span className="geo-glyph" aria-hidden="true">
              …
            </span>
            Geocoding sites…
          </>
        )}
      </p>

      <div className="report" aria-live="polite">
        {outcomes && (
          <>
            <h3>Site results</h3>
            {outcomes.map((o) => (
              <SiteOutcomeRow key={o.siteId ?? o.address} outcome={o} />
            ))}
          </>
        )}
      </div>
    </section>
  );
}

function SiteRowFields({
  index,
  row,
  canRemove,
  onChange,
  onRemove,
}: {
  index: number;
  row: SiteRow;
  canRemove: boolean;
  onChange: (patch: Partial<SiteRow>) => void;
  onRemove: () => void;
}) {
  const nameId = useId();
  const addrId = useId();
  return (
    <div className="site-row">
      <div className="field">
        <label htmlFor={addrId}>Site {index + 1} address</label>
        <input
          id={addrId}
          type="text"
          value={row.address}
          onChange={(e) => onChange({ address: e.target.value })}
        />
      </div>
      <div className="field">
        <label htmlFor={nameId}>Site name (optional)</label>
        <input
          id={nameId}
          type="text"
          value={row.name}
          onChange={(e) => onChange({ name: e.target.value })}
        />
      </div>
      {canRemove && (
        <button type="button" className="btn-danger" onClick={onRemove}>
          Remove site {index + 1}
        </button>
      )}
    </div>
  );
}

/**
 * One persisted-site result with its geocode status and (when failed) the
 * class-specific recovery path. Status is word + glyph + color (AC-012).
 */
function SiteOutcomeRow({ outcome }: { outcome: SiteOutcome }) {
  const latId = useId();
  const lngId = useId();
  const [status, setStatus] = useState(outcome.status);
  const [reason, setReason] = useState(outcome.reason);
  const [lat, setLat] = useState('');
  const [lng, setLng] = useState('');
  const [busy, setBusy] = useState(false);
  const [fixError, setFixError] = useState<string | null>(null);

  if (status === 'geocoded') {
    return (
      <p className="geo-status geo-status--ok">
        <span className="geo-glyph" aria-hidden="true">
          ✓
        </span>
        Geocoded: {outcome.name}
      </p>
    );
  }

  const kind = recoveryKind(reason);

  async function retry() {
    if (!outcome.siteId) {
      return;
    }
    setBusy(true);
    setFixError(null);
    try {
      const [point] = await defaultGeocoder.geocode([outcome.address]);
      if (!point) {
        setFixError('Still could not geocode — enter coordinates manually.');
        return;
      }
      await updateSiteLocation(outcome.siteId, point);
      setStatus('geocoded');
      setReason(null);
    } catch (err) {
      setFixError(err instanceof Error ? err.message : 'Retry failed.');
    } finally {
      setBusy(false);
    }
  }

  async function saveManual() {
    if (!outcome.siteId) {
      return;
    }
    // CR-002: reject empty/whitespace BEFORE numeric coercion (Number('') is 0)
    // and range-check before persisting, so blanks never save as 0,0.
    if (lat.trim() === '' || lng.trim() === '') {
      setFixError('Enter both latitude and longitude.');
      return;
    }
    const latN = Number(lat);
    const lngN = Number(lng);
    if (!isValidLatLng(latN, lngN)) {
      setFixError(
        'Enter valid coordinates: latitude -90 to 90, longitude -180 to 180.',
      );
      return;
    }
    setBusy(true);
    setFixError(null);
    try {
      await updateSiteLocation(outcome.siteId, { lat: latN, lng: lngN });
      setStatus('geocoded');
      setReason(null);
    } catch (err) {
      setFixError(err instanceof Error ? err.message : 'Save failed.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="recovery">
      <p className="geo-status geo-status--failed" role="alert">
        <span className="geo-glyph" aria-hidden="true">
          ⚠
        </span>
        {outcome.name}: {reasonLabel(reason)} — site saved without a location.
      </p>

      {(kind === 'retry' || kind === 'backoff') && (
        <button
          type="button"
          className="btn-secondary"
          disabled={busy}
          onClick={() => void retry()}
        >
          {busy
            ? 'Retrying…'
            : kind === 'backoff'
              ? 'Retry (rate limited — wait a moment)'
              : 'Retry geocoding'}
        </button>
      )}

      {kind === 'manual' && (
        <div className="field-inline">
          <div className="field">
            <label htmlFor={latId}>Latitude</label>
            <input
              id={latId}
              type="number"
              step="any"
              value={lat}
              onChange={(e) => setLat(e.target.value)}
            />
          </div>
          <div className="field">
            <label htmlFor={lngId}>Longitude</label>
            <input
              id={lngId}
              type="number"
              step="any"
              value={lng}
              onChange={(e) => setLng(e.target.value)}
            />
          </div>
          <button
            type="button"
            className="btn-secondary"
            disabled={busy}
            onClick={() => void saveManual()}
          >
            {busy ? 'Saving…' : 'Save coordinates'}
          </button>
        </div>
      )}

      {fixError && (
        <p role="alert" className="form-error">
          {fixError}
        </p>
      )}
    </div>
  );
}
