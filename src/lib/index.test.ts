import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  createCustomerWithSites,
  findConflicts,
  computeSaturation,
  defaultGeocoder,
  configureIdentity,
  authProvider,
  getSession,
  getActiveTenantId,
  type AuthProvider,
  type TenantProvider,
  type AppSession,
} from './index';

/**
 * EH-T2 tests (AC-008). The barrel is a PURE re-export, verified node-only:
 * representative symbols resolve through `../lib`, the identity types are
 * importable through the barrel, the `supabase` re-export is annotated
 * `@internal`, and the contract doc self-labels "reference ... not negotiated".
 * Loading the barrel also self-registers the Supabase defaults (import
 * side-effect via `./auth` / `./tenant`), proving §AC-005 holds at the barrel.
 */

describe('barrel re-exports the stable public surface (AC-008)', () => {
  it('resolves representative value symbols from each stable module', () => {
    expect(typeof createCustomerWithSites).toBe('function'); // customers
    expect(typeof findConflicts).toBe('function'); // conflicts
    expect(typeof computeSaturation).toBe('function'); // coverage
    expect(typeof defaultGeocoder.geocode).toBe('function'); // geocoder
    expect(typeof configureIdentity).toBe('function'); // identity
    expect(typeof getSession).toBe('function'); // auth free fn
    expect(typeof getActiveTenantId).toBe('function'); // tenant free fn
  });

  it('exposes the identity types through the barrel (type conformance)', () => {
    // These compile only if the types are re-exported from the barrel.
    const auth: AuthProvider = authProvider();
    const tenant: TenantProvider = {
      async getActiveTenantId() {
        return null;
      },
    };
    const session: AppSession = { user: { email: 'x@y.com' } };
    expect(typeof auth.getSession).toBe('function');
    expect(typeof tenant.getActiveTenantId).toBe('function');
    expect(session.user.email).toBe('x@y.com');
  });

  it('loading the barrel self-registers the Supabase default (no configure)', () => {
    // authProvider() resolving without a prior configureIdentity proves the
    // barrel's import of ./auth ran the self-registration side-effect (AC-005).
    expect(() => authProvider()).not.toThrow();
  });
});

describe('barrel source contract (AC-008)', () => {
  const src = readFileSync(
    fileURLToPath(new URL('./index.ts', import.meta.url)),
    'utf8',
  );

  it('annotates the supabase re-export as @internal', () => {
    expect(src).toMatch(/internal/);
    // The internal annotation sits on the supabase re-export line.
    expect(src).toMatch(/@internal[^\n]*\n\s*export \{ supabase \}/);
  });
});

describe('embed-contract.md self-labels reference, not negotiated (AC-013)', () => {
  // The doc lives at repo-root docs/; resolve from this test file's dir.
  const doc = readFileSync(
    fileURLToPath(new URL('../../docs/embed-contract.md', import.meta.url)),
    'utf8',
  );

  it('contains the "reference ... not negotiated" self-label', () => {
    expect(doc).toMatch(/reference[\s\S]*?not negotiated/i);
  });

  it('documents the provider interfaces, env vars, and the AK/HI honesty note', () => {
    expect(doc).toContain('AuthProvider');
    expect(doc).toContain('TenantProvider');
    expect(doc).toContain('VITE_ZCTA_TILES_URL');
    expect(doc).toContain('VITE_ZCTA_SOURCE_LABEL');
    expect(doc).toContain('Map of the United States');
    // listMemberships flagged exported-but-internal.
    expect(doc).toMatch(/listMemberships[\s\S]*?internal/i);
  });
});
