import Papa from 'papaparse';
import { upsertCustomer, placeSite } from './customers';
import { defaultGeocoder, type Geocoder } from './geocoder';

/**
 * CSV bulk-import orchestration (AC-009 / AC-013 / AC-014 / AC-017 / AC-019).
 *
 * Untrusted CSV is parsed CLIENT-SIDE only (no server file storage); size /
 * type / row caps are enforced BEFORE any network call. Per row: upsert the
 * customer by (tenant_id, name), geocode the ADDRESS STRING through the
 * `Geocoder` seam (CSV lat/lng is never trusted — AC-019), and persist the site.
 * A per-row report maps 1:1 to input rows with exactly one outcome each.
 */

export interface ImportLimits {
  maxBytes: number;
  maxRows: number;
}

export const DEFAULT_LIMITS: ImportLimits = {
  maxBytes: 5 * 1024 * 1024, // ~5 MB
  maxRows: 1000,
};

const REQUIRED_COLUMNS = ['customer_name', 'address'] as const;
const KNOWN_COLUMNS = ['customer_name', 'site_name', 'address', 'vertical'] as const;

export type RowOutcome =
  | 'created'
  | 'geocode-failed'
  | 'skipped-duplicate'
  | 'missing-required-column'
  | 'error';

export interface RowResult {
  /** 1-based input row number (data rows; the header is row 0). */
  row: number;
  customerName: string;
  address: string;
  outcome: RowOutcome;
  message: string;
}

export interface ImportReport {
  rows: RowResult[];
  /** Columns present in the file that are not part of the known schema. */
  unknownColumns: string[];
  /** Required columns entirely absent from the header. */
  missingColumns: string[];
  cancelled: boolean;
}

export interface ImportOptions {
  geocoder?: Geocoder;
  onProgress?: (done: number, total: number) => void;
  signal?: AbortSignal;
  limits?: ImportLimits;
}

/** A thrown file-level rejection (size / type) — surfaced distinctly from rows. */
export class CsvValidationError extends Error {}

/** Pre-network file validation (size + type). Returns an error string or null. */
export function validateFile(
  file: File,
  limits: ImportLimits = DEFAULT_LIMITS,
): string | null {
  const isCsv =
    file.name.toLowerCase().endsWith('.csv') ||
    file.type === 'text/csv' ||
    file.type === 'application/vnd.ms-excel';
  if (!isCsv) {
    return 'File must be a .csv file.';
  }
  if (file.size > limits.maxBytes) {
    return `File is too large (max ${Math.round(limits.maxBytes / (1024 * 1024))} MB).`;
  }
  return null;
}

/** Normalize an address for within-import dedup: trim + collapse ws + lowercase. */
function normalizeAddress(address: string): string {
  return address.trim().replace(/\s+/g, ' ').toLowerCase();
}

function normalizeName(name: string): string {
  return name.trim().toLowerCase();
}

function parseCsv(file: File): Promise<Papa.ParseResult<Record<string, string>>> {
  return new Promise((resolve, reject) => {
    Papa.parse<Record<string, string>>(file, {
      header: true,
      skipEmptyLines: true,
      transformHeader: (h) => h.trim().toLowerCase(),
      complete: resolve,
      error: (err: Error) => reject(err),
    });
  });
}

/**
 * Run the import. File-level rejections throw `CsvValidationError` (BEFORE any
 * network call). Everything else is reported per-row; the report is returned
 * even on total failure so the caller can always render it.
 */
export async function importCsv(
  file: File,
  options: ImportOptions = {},
): Promise<ImportReport> {
  const limits = options.limits ?? DEFAULT_LIMITS;
  const geocoder = options.geocoder ?? defaultGeocoder;

  // 1) Pre-network file validation.
  const fileError = validateFile(file, limits);
  if (fileError) {
    throw new CsvValidationError(fileError);
  }

  // 2) Parse client-side (no network).
  const parsed = await parseCsv(file);
  const fields = parsed.meta.fields ?? [];
  const dataRows = parsed.data;

  // 3) Row cap (still pre-network).
  if (dataRows.length > limits.maxRows) {
    throw new CsvValidationError(
      `Too many rows (${dataRows.length}; max ${limits.maxRows}).`,
    );
  }

  const unknownColumns = fields.filter(
    (f) => !KNOWN_COLUMNS.includes(f as (typeof KNOWN_COLUMNS)[number]),
  );
  const missingColumns = REQUIRED_COLUMNS.filter((c) => !fields.includes(c));

  const report: ImportReport = {
    rows: [],
    unknownColumns,
    missingColumns,
    cancelled: false,
  };

  // Within-import dedup + customer-id cache.
  const seenSites = new Set<string>();
  const customerIds = new Map<string, string>();
  const total = dataRows.length;

  for (let i = 0; i < dataRows.length; i++) {
    if (options.signal?.aborted) {
      report.cancelled = true;
      // Remaining rows (this one included) are reported as not-processed.
      for (let j = i; j < dataRows.length; j++) {
        const r = dataRows[j];
        report.rows.push({
          row: j + 1,
          customerName: (r.customer_name ?? '').trim(),
          address: (r.address ?? '').trim(),
          outcome: 'error',
          message: 'Cancelled before processing.',
        });
      }
      break;
    }

    const raw = dataRows[i];
    const customerName = (raw.customer_name ?? '').trim();
    const address = (raw.address ?? '').trim();
    const siteName = (raw.site_name ?? '').trim();
    // Optional vertical column → the customer's vertical (lowercased to match the
    // controlled VERTICAL_OPTIONS tokens). Only set on customer CREATE; the
    // non-destructive upsert never clobbers a vertical a prior row/add stored,
    // so the first row for a given brand wins.
    const vertical = (raw.vertical ?? '').trim().toLowerCase() || null;
    const rowNo = i + 1;

    // Missing required columns — precise message.
    const missingForRow: string[] = [];
    if (!customerName) missingForRow.push('customer_name');
    if (!address) missingForRow.push('address');
    if (missingForRow.length > 0) {
      report.rows.push({
        row: rowNo,
        customerName,
        address,
        outcome: 'missing-required-column',
        message: `Missing required: ${missingForRow.join(', ')}.`,
      });
      options.onProgress?.(i + 1, total);
      continue;
    }

    // Within-import site dedup: (customer_name, normalized address).
    const dedupKey = `${normalizeName(customerName)}::${normalizeAddress(address)}`;
    if (seenSites.has(dedupKey)) {
      report.rows.push({
        row: rowNo,
        customerName,
        address,
        outcome: 'skipped-duplicate',
        message: 'Duplicate of an earlier row in this import.',
      });
      options.onProgress?.(i + 1, total);
      continue;
    }
    seenSites.add(dedupKey);

    try {
      // Collapse duplicate customer names within the tenant to one row.
      const custKey = normalizeName(customerName);
      let customerId = customerIds.get(custKey);
      if (!customerId) {
        customerId = await upsertCustomer(customerName, {}, vertical);
        customerIds.set(custKey, customerId);
      }

      // Geocode the ADDRESS only — any CSV lat/lng is ignored (AC-019).
      const [result] = await geocoder.geocodeDetailed([address]);
      // site.name is NOT NULL: default an absent site_name to the address.
      const name = siteName || address;
      await placeSite(customerId, name, address, result.point);

      if (result.point) {
        report.rows.push({
          row: rowNo,
          customerName,
          address,
          outcome: 'created',
          message: 'Created and geocoded.',
        });
      } else {
        report.rows.push({
          row: rowNo,
          customerName,
          address,
          outcome: 'geocode-failed',
          message: `Created without a location (${result.reason ?? 'geocoding failed'}).`,
        });
      }
    } catch (err) {
      report.rows.push({
        row: rowNo,
        customerName,
        address,
        outcome: 'error',
        message: err instanceof Error ? err.message : 'Import error.',
      });
    }

    options.onProgress?.(i + 1, total);
  }

  return report;
}

/** Build a downloadable error CSV from a report (AC-014 copy/download errors). */
export function errorsToCsv(report: ImportReport): string {
  const failed = report.rows.filter((r) => r.outcome !== 'created');
  const header = 'row,customer_name,address,outcome,message';
  const lines = failed.map(
    (r) =>
      `${r.row},${csvCell(r.customerName)},${csvCell(r.address)},${r.outcome},${csvCell(r.message)}`,
  );
  return [header, ...lines].join('\n');
}

export function csvCell(value: string): string {
  // SA-004: neutralize CSV formula injection. A cell beginning with a formula
  // trigger (=, +, -, @, tab, CR) is prefixed with a single quote so a
  // spreadsheet treats it as text, NOT a formula. Applied BEFORE RFC-4180
  // quote-escaping below.
  let safe = value;
  if (/^[=+\-@\t\r]/.test(safe)) {
    safe = `'${safe}`;
  }
  if (/[",\n]/.test(safe)) {
    return `"${safe.replace(/"/g, '""')}"`;
  }
  return safe;
}
