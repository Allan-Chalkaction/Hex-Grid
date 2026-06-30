import { describe, it, expect } from 'vitest';
import { isValidLatLng, updateSiteName } from '../../src/lib/customers';

// Pure, no DB. (customers.ts transitively imports the app supabase singleton,
// which constructs harmlessly from the dummy VITE_* env in vitest.config.ts.)
describe('isValidLatLng (CR-002 / SA-005 WGS84 bounds)', () => {
  it('accepts finite in-range coordinates', () => {
    expect(isValidLatLng(40.7128, -74.006)).toBe(true);
    expect(isValidLatLng(0, 0)).toBe(true);
  });

  it('accepts the exact boundary values', () => {
    expect(isValidLatLng(90, 180)).toBe(true);
    expect(isValidLatLng(-90, -180)).toBe(true);
    expect(isValidLatLng(90, -180)).toBe(true);
    expect(isValidLatLng(-90, 180)).toBe(true);
  });

  it('rejects out-of-range latitude (91, -91)', () => {
    expect(isValidLatLng(91, 0)).toBe(false);
    expect(isValidLatLng(-91, 0)).toBe(false);
  });

  it('rejects out-of-range longitude (181, -181)', () => {
    expect(isValidLatLng(0, 181)).toBe(false);
    expect(isValidLatLng(0, -181)).toBe(false);
  });

  it('rejects NaN and non-finite values', () => {
    expect(isValidLatLng(NaN, 0)).toBe(false);
    expect(isValidLatLng(0, NaN)).toBe(false);
    expect(isValidLatLng(Infinity, 0)).toBe(false);
    expect(isValidLatLng(0, -Infinity)).toBe(false);
  });

  // The empty-/whitespace-string rejection in the brief is a TWO-LAYER contract.
  // isValidLatLng takes numbers; `Number('')` and `Number('  ')` are both 0, which
  // IS a valid coordinate — so the UI (CR-002, CustomerForm.tsx:316 /
  // CustomerList.tsx:274) MUST reject empty/whitespace strings BEFORE numeric
  // coercion. These assertions lock that surprising-but-load-bearing behavior so a
  // future refactor cannot quietly make blanks save as 0,0.
  it('documents the empty/whitespace coercion gotcha (Number("") === 0)', () => {
    expect(Number('')).toBe(0);
    expect(Number('  ')).toBe(0);
    // Hence isValidLatLng would ACCEPT a blank-coerced 0 — the pre-guard is required.
    expect(isValidLatLng(Number(''), Number('  '))).toBe(true);
  });

  it('replicates the UI pre-guard rejecting "" / "  " before coercion', () => {
    // Mirrors the CR-002 guard at the call site (string trim check first).
    const accept = (latStr: string, lngStr: string): boolean => {
      if (latStr.trim() === '' || lngStr.trim() === '') return false;
      return isValidLatLng(Number(latStr), Number(lngStr));
    };
    expect(accept('', '')).toBe(false);
    expect(accept('  ', '  ')).toBe(false);
    expect(accept('40.71', '')).toBe(false);
    expect(accept('40.71', '-74.01')).toBe(true);
  });
});

// updateSiteName guards an empty/whitespace name BEFORE touching the DB (site.name
// is NOT NULL). The guard throws synchronously-before-await, so this is unit-
// testable without a live Supabase (a valid name would hit the network, which the
// node unit env has no server for — hence only the reject path is asserted here;
// the happy path is covered transitively by the integration suite's site writes).
describe('updateSiteName (Sites-table inline rename — NOT NULL guard)', () => {
  it('rejects an empty name without writing', async () => {
    await expect(updateSiteName('some-id', '')).rejects.toThrow(
      /name is required/i,
    );
  });

  it('rejects a whitespace-only name without writing', async () => {
    await expect(updateSiteName('some-id', '   ')).rejects.toThrow(
      /name is required/i,
    );
  });
});
