import { useId, useState } from 'react';
import {
  createCustomerWithSites,
  updateSiteLocation,
  type SiteOutcome,
} from '../lib/customers';
import {
  defaultGeocoder,
  type GeocodeFailureReason,
} from '../lib/geocoder';

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
  name: string;
  address: string;
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

  const [customerName, setCustomerName] = useState('');
  const [vertical, setVertical] = useState('');
  const [rows, setRows] = useState<SiteRow[]>([{ name: '', address: '' }]);
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [outcomes, setOutcomes] = useState<SiteOutcome[] | null>(null);

  function updateRow(i: number, patch: Partial<SiteRow>) {
    setRows((prev) => prev.map((r, idx) => (idx === i ? { ...r, ...patch } : r)));
  }

  function addRow() {
    setRows((prev) => [...prev, { name: '', address: '' }]);
  }

  function removeRow(i: number) {
    setRows((prev) =>
      prev.length === 1 ? prev : prev.filter((_r, idx) => idx !== i),
    );
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setError(null);
    setOutcomes(null);

    const filled = rows.filter((r) => r.address.trim().length > 0);
    if (!customerName.trim()) {
      setError('Enter a customer name.');
      return;
    }
    if (filled.length === 0) {
      setError('Add at least one site with an address.');
      return;
    }

    setSubmitting(true);
    try {
      const result = await createCustomerWithSites({
        customerName: customerName.trim(),
        attributes: vertical.trim() ? { vertical: vertical.trim() } : {},
        sites: filled.map((r) => ({
          name: r.name.trim() || undefined,
          address: r.address.trim(),
        })),
      });
      setOutcomes(result.sites);
      // Reset the site rows for the next add; keep the brand fields.
      setRows([{ name: '', address: '' }]);
      onChanged();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not add customer.');
    } finally {
      setSubmitting(false);
    }
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
          <label htmlFor={verticalId}>Vertical (optional)</label>
          <input
            id={verticalId}
            type="text"
            value={vertical}
            onChange={(e) => setVertical(e.target.value)}
          />
        </div>

        <fieldset>
          <legend>Sites (at least one required)</legend>
          <div className="site-rows">
            {rows.map((row, i) => (
              <SiteRowFields
                key={i}
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

        <button type="submit" disabled={submitting}>
          {submitting ? 'Adding & geocoding…' : 'Add customer'}
        </button>
      </form>

      {submitting && (
        <p className="geo-status geo-status--pending" aria-live="polite">
          <span className="geo-glyph" aria-hidden="true">
            ⏳
          </span>
          Geocoding sites…
        </p>
      )}

      {outcomes && (
        <div className="report" aria-live="polite">
          <h3>Site results</h3>
          {outcomes.map((o) => (
            <SiteOutcomeRow key={o.siteId ?? o.address} outcome={o} />
          ))}
        </div>
      )}
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
    const latN = Number(lat);
    const lngN = Number(lng);
    if (!Number.isFinite(latN) || !Number.isFinite(lngN)) {
      setFixError('Enter valid numeric latitude and longitude.');
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
          ✗
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
