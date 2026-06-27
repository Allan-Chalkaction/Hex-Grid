import { describe, it, expect, vi } from 'vitest';

// Mock the DB-touching seam so the import orchestration runs fully OFFLINE: the
// parsing / dedup / missing-column logic is exercised without any PostgREST call.
// (csvImport imports upsertCustomer + placeSite from ./customers.)
vi.mock('../../src/lib/customers', () => ({
  upsertCustomer: vi.fn(async (name: string) => `cust:${name.toLowerCase()}`),
  placeSite: vi.fn(async () => `site:${crypto.randomUUID()}`),
}));

import { importCsv, csvCell } from '../../src/lib/csvImport';
import type { Geocoder } from '../../src/lib/geocoder';

// Deterministic fake geocoders (the `Geocoder` seam) — no Census/network call.
const okGeocoder: Geocoder = {
  geocode: async (addrs) => addrs.map(() => ({ lat: 40.5, lng: -74.5 })),
  geocodeDetailed: async (addrs) =>
    addrs.map(() => ({ point: { lat: 40.5, lng: -74.5 }, reason: null })),
};
const failGeocoder: Geocoder = {
  geocode: async (addrs) => addrs.map(() => null),
  geocodeDetailed: async (addrs) =>
    addrs.map(() => ({ point: null, reason: 'no-match' as const })),
};

function csvFile(content: string): File {
  return new File([content], 'test.csv', { type: 'text/csv' });
}

describe('csvCell (SA-004 formula-injection + RFC-4180 quoting)', () => {
  it('passes through a plain value unchanged', () => {
    expect(csvCell('Acme')).toBe('Acme');
    expect(csvCell('123 Main St')).toBe('123 Main St');
  });

  it('RFC-4180 quotes values containing comma / quote / newline', () => {
    expect(csvCell('a,b')).toBe('"a,b"');
    expect(csvCell('a"b')).toBe('"a""b"');
    expect(csvCell('line1\nline2')).toBe('"line1\nline2"');
  });

  it('neutralizes formula-injection triggers (=, +, -, @, tab, CR) with a leading quote', () => {
    expect(csvCell('=SUM(A1)')).toBe("'=SUM(A1)");
    expect(csvCell('+1')).toBe("'+1");
    expect(csvCell('-1')).toBe("'-1");
    expect(csvCell('@x')).toBe("'@x");
    expect(csvCell('\tcmd')).toBe("'\tcmd");
    expect(csvCell('\rcmd')).toBe("'\rcmd");
  });

  it('applies injection-neutralization BEFORE RFC-4180 quoting', () => {
    // Starts with '=' AND contains a comma: prefix then quote the whole cell.
    expect(csvCell('=1,2')).toBe('"\'=1,2"');
  });

  it('does not neutralize a trigger char that is not leading', () => {
    expect(csvCell('a=b')).toBe('a=b');
    expect(csvCell('a+b')).toBe('a+b');
  });
});

describe('importCsv orchestration (offline; fake geocoder)', () => {
  it('creates a geocoded site for a valid row', async () => {
    const report = await importCsv(
      csvFile('customer_name,address\nAcme,123 Main St\n'),
      { geocoder: okGeocoder },
    );
    expect(report.rows).toHaveLength(1);
    expect(report.rows[0].outcome).toBe('created');
    expect(report.missingColumns).toEqual([]);
    expect(report.unknownColumns).toEqual([]);
  });

  it('reports geocode-failed when the address does not geocode', async () => {
    const report = await importCsv(
      csvFile('customer_name,address\nAcme,Nowhere\n'),
      { geocoder: failGeocoder },
    );
    expect(report.rows[0].outcome).toBe('geocode-failed');
  });

  it('flags a row missing a required field (empty address)', async () => {
    const report = await importCsv(
      csvFile('customer_name,address\nAcme,\n'),
      { geocoder: okGeocoder },
    );
    expect(report.rows[0].outcome).toBe('missing-required-column');
    expect(report.rows[0].message).toContain('address');
  });

  it('dedups a repeated (customer, address) within the import (seenSites)', async () => {
    const report = await importCsv(
      csvFile('customer_name,address\nAcme,123 Main St\nAcme,123 main st\n'),
      { geocoder: okGeocoder },
    );
    expect(report.rows).toHaveLength(2);
    expect(report.rows[0].outcome).toBe('created');
    // Second row dedups (normalized: trim + collapse ws + lowercase).
    expect(report.rows[1].outcome).toBe('skipped-duplicate');
  });

  it('detects a required column entirely absent from the header', async () => {
    const report = await importCsv(
      csvFile('customer_name\nAcme\n'),
      { geocoder: okGeocoder },
    );
    expect(report.missingColumns).toContain('address');
    expect(report.rows[0].outcome).toBe('missing-required-column');
  });

  it('reports unknown (non-schema) columns present in the header', async () => {
    const report = await importCsv(
      csvFile('customer_name,address,foo\nAcme,123 Main St,bar\n'),
      { geocoder: okGeocoder },
    );
    expect(report.unknownColumns).toContain('foo');
    expect(report.rows[0].outcome).toBe('created');
  });
});
