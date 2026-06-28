import { useId, useRef, useState } from 'react';
import {
  importCsv,
  errorsToCsv,
  CsvValidationError,
  type ImportReport,
  type RowOutcome,
} from '../lib/csvImport';

/**
 * A11Y-005: map a raw outcome identifier to a user-friendly word + glyph,
 * mirroring the SiteOutcomeRow vocabulary. The glyph is aria-hidden; the word
 * is the screen-reader text.
 */
function outcomeLabel(outcome: RowOutcome): { glyph: string; word: string } {
  switch (outcome) {
    case 'created':
      return { glyph: '✓', word: 'Created' };
    case 'geocode-failed':
      return { glyph: '⚠', word: 'Geocode failed' };
    case 'skipped-duplicate':
      return { glyph: '–', word: 'Skipped (duplicate)' };
    case 'missing-required-column':
      return { glyph: '⚠', word: 'Missing required column' };
    case 'error':
    default:
      return { glyph: '⚠', word: 'Error' };
  }
}

/**
 * CSV bulk-import UI (AC-013 / AC-014 / AC-019).
 *
 * Accepts a CSV (one row per site: customer_name, site_name?, address, …),
 * validates size/type/row caps CLIENT-SIDE before any network call, and shows an
 * in-flight <progress> with a cancel control. A per-row results report
 * (created / geocode-failed / skipped-duplicate / missing-required-column) is
 * ALWAYS rendered — even on total failure — with a copy/download-errors
 * affordance. On success `onChanged()` refreshes the lifted map state (AC-010).
 */
export function CustomerImport({ onChanged }: { onChanged: () => void }) {
  const fileId = useId();
  const progressId = useId();
  const [fileError, setFileError] = useState<string | null>(null);
  const [report, setReport] = useState<ImportReport | null>(null);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState<{ done: number; total: number }>({
    done: 0,
    total: 0,
  });
  const fileInputRef = useRef<HTMLInputElement>(null);
  const abortRef = useRef<AbortController | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setFileError(null);
    setReport(null);

    const file = fileInputRef.current?.files?.[0];
    if (!file) {
      setFileError('Choose a CSV file to import.');
      return;
    }

    const controller = new AbortController();
    abortRef.current = controller;
    setBusy(true);
    setProgress({ done: 0, total: 0 });
    try {
      const result = await importCsv(file, {
        signal: controller.signal,
        onProgress: (done, total) => setProgress({ done, total }),
      });
      setReport(result);
      onChanged();
    } catch (err) {
      if (err instanceof CsvValidationError) {
        setFileError(err.message);
      } else {
        setFileError(
          err instanceof Error ? err.message : 'Could not import the file.',
        );
      }
    } finally {
      setBusy(false);
      abortRef.current = null;
    }
  }

  function cancel() {
    abortRef.current?.abort();
  }

  function downloadErrors() {
    if (!report) {
      return;
    }
    const blob = new Blob([errorsToCsv(report)], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'import-errors.csv';
    a.click();
    URL.revokeObjectURL(url);
  }

  async function copyErrors() {
    if (!report) {
      return;
    }
    try {
      await navigator.clipboard.writeText(errorsToCsv(report));
    } catch {
      // Clipboard unavailable (e.g. insecure context) — download is the fallback.
    }
  }

  const createdCount = report?.rows.filter((r) => r.outcome === 'created').length;

  return (
    <section className="panel-section" aria-label="Import customers from CSV">
      <h2>Import from CSV</h2>
      <p className="helper-text">
        One row per site: <code>customer_name</code>, <code>site_name</code>{' '}
        (optional), <code>address</code>. Extra columns are ignored. Max 5 MB /
        1000 rows.
      </p>
      <form onSubmit={handleSubmit} noValidate>
        <div className="field">
          <label htmlFor={fileId}>CSV file</label>
          <input id={fileId} ref={fileInputRef} type="file" accept=".csv,text/csv" />
        </div>
        {fileError && (
          <p role="alert" aria-live="assertive" className="form-error">
            {fileError}
          </p>
        )}
        <button type="submit" disabled={busy}>
          {busy ? 'Importing…' : 'Import CSV'}
        </button>
      </form>

      {/* A11Y-003: render the live regions unconditionally; only the CONTENT
          toggles, so screen readers observe them from first paint. */}
      <div className="import-progress" aria-live="polite">
        {busy && (
          <>
            <label htmlFor={progressId}>Importing</label>
            <progress
              id={progressId}
              value={progress.done}
              max={progress.total || undefined}
            />
            <span>
              {progress.done}
              {progress.total ? ` / ${progress.total}` : ''}
            </span>
            <button type="button" className="btn-secondary" onClick={cancel}>
              Cancel
            </button>
          </>
        )}
      </div>

      <div className="report" aria-live="polite">
        {report && (
          <>
            <h3>Import results</h3>
            <p>
              {createdCount} created
              {report.cancelled ? ' (import was cancelled)' : ''}.
            </p>
            {report.missingColumns.length > 0 && (
              <p role="alert" className="form-error">
                Missing required column(s): {report.missingColumns.join(', ')}.
              </p>
            )}
            {report.unknownColumns.length > 0 && (
              <p className="helper-text">
                Ignored unknown column(s): {report.unknownColumns.join(', ')}.
              </p>
            )}
            <ul>
              {report.rows.map((r) => {
                const label = outcomeLabel(r.outcome);
                return (
                  <li
                    key={r.row}
                    className={`report-row report-row--${r.outcome}`}
                  >
                    <span>Row {r.row}</span>
                    <span>{r.customerName || '(no customer)'}</span>
                    <span>{r.address || '(no address)'}</span>
                    <span className="geo-status">
                      <span className="geo-glyph" aria-hidden="true">
                        {label.glyph}
                      </span>
                      {label.word}
                    </span>
                    <span>{r.message}</span>
                  </li>
                );
              })}
            </ul>
            <div className="errors-actions">
              <button
                type="button"
                className="btn-secondary"
                onClick={() => void copyErrors()}
              >
                Copy errors
              </button>
              <button
                type="button"
                className="btn-secondary"
                onClick={downloadErrors}
              >
                Download errors (CSV)
              </button>
            </div>
          </>
        )}
      </div>
    </section>
  );
}
