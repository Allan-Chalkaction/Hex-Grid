import { describe, it, expect, afterEach } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import {
  configureIdentity,
  authProvider,
  tenantProvider,
  type AuthProvider,
  type TenantProvider,
  type AppSession,
} from './providers';
// Importing the seam modules triggers the Supabase reference impls to
// self-register as the defaults (import side-effect). The named imports also
// give us the free-function delegators to observe injection through (AC-006/007).
import { getSession as authGetSession } from './auth';
import { getActiveTenantId as tenantGetActiveTenantId } from './tenant';

/**
 * EH-T1 tests (AC-001..007). The project is node-only (no jsdom/RTL), so the
 * seam is verified by PURE-logic / type-conformance / grep — never a component
 * render. A fake provider is constructed WITHOUT importing `@supabase/supabase-js`
 * (this file imports zero supabase-js), proving the boundary is supabase-js-free
 * (AC-002). The Supabase defaults are captured at module load and restored after
 * every test so injection is isolated (no `reset*` test-only surface needed).
 */

// Captured BEFORE any configureIdentity call → the self-registered Supabase
// defaults (AC-005). Used to restore + to assert default resolution.
const defaultAuth = authProvider();
const defaultTenant = tenantProvider();

afterEach(() => {
  // Restore the defaults so a configured fake never leaks into the next test.
  configureIdentity({ auth: defaultAuth, tenant: defaultTenant });
});

/** A fake AuthProvider built with provider-owned shapes only — no supabase-js. */
const fakeAuth: AuthProvider = {
  async getSession(): Promise<AppSession | null> {
    return { user: { email: 'fake@example.com' } };
  },
  async signIn() {
    return { session: { user: { email: 'fake@example.com' } }, error: null };
  },
  async signOut() {},
  onAuthStateChange(callback) {
    callback({ user: { email: 'fake@example.com' } });
    return { unsubscribe: () => {} };
  },
};

/** A fake TenantProvider — `getActiveTenantId` only (no `listMemberships`). */
const fakeTenant: TenantProvider = {
  async getActiveTenantId(): Promise<string | null> {
    return 'tenant-fake';
  },
};

describe('provider interface shape (AC-001)', () => {
  it('the Supabase default satisfies AuthProvider (the four consumed methods)', () => {
    // Assignment compiles (type conformance) + the four methods exist.
    const auth: AuthProvider = defaultAuth;
    expect(typeof auth.getSession).toBe('function');
    expect(typeof auth.signIn).toBe('function');
    expect(typeof auth.signOut).toBe('function');
    expect(typeof auth.onAuthStateChange).toBe('function');
  });

  it('the Supabase default satisfies TenantProvider (getActiveTenantId only)', () => {
    const tenant: TenantProvider = defaultTenant;
    expect(typeof tenant.getActiveTenantId).toBe('function');
    // listMemberships is DELIBERATELY EXCLUDED from the interface (AC-001).
    expect('listMemberships' in tenant).toBe(false);
  });
});

describe('supabase-js-free boundary (AC-002/003)', () => {
  it('a fake AuthProvider constructs with provider-owned shapes (no supabase-js)', async () => {
    // This whole file imports no `@supabase/supabase-js`; `fakeAuth` typechecks
    // against AuthProvider purely from provider-owned shapes (AppSession etc.).
    const s = await fakeAuth.getSession();
    expect(s?.user.email).toBe('fake@example.com');
  });

  it('an AppSession flows through a fake provider unchanged (AC-003)', async () => {
    let observed: AppSession | null = null;
    const handle = fakeAuth.onAuthStateChange((session) => {
      observed = session;
    });
    expect(observed).toEqual({ user: { email: 'fake@example.com' } });
    // The unsubscribe handle is callable (the existing call-site shape).
    expect(typeof handle.unsubscribe).toBe('function');
    handle.unsubscribe();
  });
});

describe('configureIdentity single injection point (AC-004)', () => {
  it('swaps the auth provider and leaves tenant on its default', () => {
    configureIdentity({ auth: fakeAuth });
    expect(authProvider()).toBe(fakeAuth);
    expect(tenantProvider()).toBe(defaultTenant);
  });

  it('a fake auth getSession is observed through the auth.ts free function', async () => {
    configureIdentity({ auth: fakeAuth });
    const s = await authGetSession();
    expect(s?.user.email).toBe('fake@example.com');
  });

  it('swaps the tenant provider observed through the tenant.ts free function', async () => {
    configureIdentity({ tenant: fakeTenant });
    expect(await tenantGetActiveTenantId()).toBe('tenant-fake');
    // The auth side stays on its default when only tenant is configured.
    expect(authProvider()).toBe(defaultAuth);
  });
});

describe('default resolution with no configure (AC-005)', () => {
  it('resolves to the self-registered Supabase defaults', () => {
    // afterEach restored defaults; with no override active, resolution = default.
    expect(authProvider()).toBe(defaultAuth);
    expect(tenantProvider()).toBe(defaultTenant);
  });

  it('the delegators resolve a provider without throwing (no-config path)', () => {
    expect(() => authProvider()).not.toThrow();
    expect(() => tenantProvider()).not.toThrow();
  });
});

describe('delegator wiring — consumers reach the active provider (AC-006/007)', () => {
  const authSrc = readFileSync(
    fileURLToPath(new URL('./auth.ts', import.meta.url)),
    'utf8',
  );
  const tenantSrc = readFileSync(
    fileURLToPath(new URL('./tenant.ts', import.meta.url)),
    'utf8',
  );

  it('auth.ts free functions call authProvider().<m>() (delegators, not re-impl)', () => {
    expect(authSrc).toContain('authProvider().getSession()');
    expect(authSrc).toContain('authProvider().signIn(');
    expect(authSrc).toContain('authProvider().signOut()');
    expect(authSrc).toContain('authProvider().onAuthStateChange(');
    // The Supabase impl self-registers as the default.
    expect(authSrc).toContain('registerDefaultAuthProvider(supabaseAuthProvider)');
  });

  it('tenant.ts getActiveTenantId calls tenantProvider().getActiveTenantId()', () => {
    expect(tenantSrc).toContain('tenantProvider().getActiveTenantId()');
    expect(tenantSrc).toContain(
      'registerDefaultTenantProvider(supabaseTenantProvider)',
    );
    // tenant resolution still reads `membership` (RLS authority unchanged — AC-015).
    expect(tenantSrc).toContain("from('membership')");
  });
});

describe('no supabase-js leak in the providers.ts public surface (AC-002)', () => {
  const src = readFileSync(
    fileURLToPath(new URL('./providers.ts', import.meta.url)),
    'utf8',
  );

  it('references no @supabase/supabase-js import or Session/Subscription type', () => {
    expect(src).not.toMatch(/@supabase\/supabase-js/);
    expect(src).not.toMatch(/\bSession\b/);
    expect(src).not.toMatch(/\bSubscription\b/);
  });

  it('does not declare listMemberships on the TenantProvider interface (AC-001)', () => {
    expect(src).not.toMatch(/\blistMemberships\b/);
  });
});
