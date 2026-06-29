# hex-grid embed contract (reference)

> **This is a reference contract, not negotiated.** It DESCRIBES what hex-grid
> exposes today for later embedding in a parent application — it is not an API
> negotiated against a specific parent. Shapes here are provisional and will be
> finalized when a real parent integration is scoped (Wave 6 / ADR-006). No
> behavior changed when this document was written; it formalizes the seams W1–W5
> already shipped.

This document enumerates the **public library surface** (`src/lib`), the
**identity/tenant provider contract** a parent implements to plug in its own
auth, the **environment variables** hex-grid reads, and two **honesty notes**
(map extent, ZCTA source kind).

---

## 1. Public library surface (`src/lib`)

A parent depends on the single import root `src/lib` (the barrel `src/lib/index.ts`).
Importing the barrel also self-registers the Supabase reference providers as the
defaults (see §2), so an app that never calls `configureIdentity` behaves exactly
as it does today.

### Stability tiers (ADR-006 D2)

| Tier | Surface | Notes |
|------|---------|-------|
| **Stable** | `customers` | customer + site CRUD: `createCustomerWithSites`, `upsertCustomer`, `placeSite`, `updateSiteLocation`, `updateSiteAddress`, `updateSiteRadius`, `updateCustomerVertical`, `updateCustomerSelfConflict`, `deleteCustomer`, `VERTICAL_OPTIONS`, `verticalLabel`, `isValidLatLng`, + their types. |
| **Stable** | `conflicts` | `findConflicts`, `findSiteConflicts`, `Conflict`. |
| **Stable** | `coverage` | `computeSaturation`, `coverageForCells`, `rankOpenCells`, `resolutionForZoom`, `haversineMi`, `effectiveRadiusMi`, the saturation types + tuning constants. |
| **Stable** | `geocoder` | the `Geocoder` interface + the shared `defaultGeocoder` value (consumers depend on the type, not the concrete class). |
| **Stable** | `identity` | the `AuthProvider` / `TenantProvider` interfaces, `configureIdentity`, the `authProvider()`/`tenantProvider()` accessors, and the `auth.ts` / `tenant.ts` free functions (`getSession`, `signIn`, `signOut`, `onAuthStateChange`, `getActiveTenantId`). See §2. |
| **Internal** | `supabase` | the supabase-js client singleton, re-exported from the barrel annotated `@internal`. Present for app bootstrap only — **NOT** a parent-stable dependency; it may change without notice. |
| **Internal** | `listMemberships` | exported from `tenant.ts` (and the barrel) but **internal** — it has no consumer in `src/` and is deliberately EXCLUDED from the `TenantProvider` interface. Do not depend on it. |

---

## 2. Identity / tenant provider contract

The identity seam is **supabase-js-free**: a parent implements two small
interfaces using only provider-owned shapes — **no `@supabase/supabase-js`
dependency required** (ADR-006 / AC-002). The Supabase reference impls live in
`src/lib/auth.ts` and `src/lib/tenant.ts` and map the supabase-js shapes to the
provider-owned shapes at the seam.

### Provider-owned boundary shapes

```ts
interface AppSession {
  user: { email: string | null };   // the only field any consumer reads
}
type Unsubscribe = () => void;
interface SignInResult {
  session: AppSession | null;
  error: string | null;         // null on success
}
```

### `AuthProvider`

```ts
interface AuthProvider {
  getSession(): Promise<AppSession | null>;
  signIn(email: string, password: string): Promise<SignInResult>;
  signOut(): Promise<void>;
  onAuthStateChange(
    callback: (session: AppSession | null) => void,
  ): { unsubscribe: Unsubscribe };
}
```

> **`signIn` / `signOut` are the reference / dev-login arm.** They exist to drive
> the built-in `AuthGate` email+password dev login. A **parent-hosted login** that
> manages sessions itself need not meaningfully implement `signIn`/`signOut` — it
> can stub them (e.g. throw / no-op) and drive the app purely through `getSession`
> + `onAuthStateChange`. Only `getSession` and `onAuthStateChange` are load-bearing
> for a parent-hosted identity source.

### `TenantProvider`

```ts
interface TenantProvider {
  getActiveTenantId(): Promise<string | null>;
}
```

`listMemberships` is **NOT** part of this interface (no consumer; see §1).

### Swapping the provider

```ts
import { configureIdentity } from 'hex-grid/src/lib';

// Call ONCE at bootstrap. The unspecified role stays on its Supabase default.
configureIdentity({ auth: myAuthProvider /*, tenant: myTenantProvider */ });
```

There is **no registry, no env/runtime provider selection, no DI container** —
one default impl per role + one `configureIdentity` injection point
(swap-by-code-edit at bootstrap). RLS remains the authorization authority
server-side (it keys off the `membership` table / `auth_tenant_ids()`), so
swapping the identity *source* never changes a policy.

---

## 3. Environment variables

| Variable | Read by | Purpose | Default when unset |
|----------|---------|---------|--------------------|
| `VITE_SUPABASE_URL` | `supabaseClient.ts` | Supabase project URL (reference impl). | required (throws) |
| `VITE_SUPABASE_ANON_KEY` | `supabaseClient.ts` | Supabase anon (public, RLS-gated) key. | required (throws) |
| `VITE_ZCTA_TILES_URL` | `zctaSource.ts` | Vector-tile source URL for the ZIP/ZCTA overlay. When unset the ZIP toggle is disabled (graceful degrade). | unset → overlay disabled |
| `VITE_ZCTA_SOURCE_LABEL` | `zctaSource.ts` | Human label for the configured ZCTA source kind (e.g. `"USPS ZIP"`). | `"ZCTA approximation"` |

The anon key + ZCTA token ride in env (the token is in the `VITE_ZCTA_TILES_URL`
value); never hardcode them. The service-role key is never used in the client.

---

## 4. Honesty notes

### Map extent (AK / HI)

The map's accessible name is **"Map of the United States"** (not "continental").
Alaska and Hawaii are pannable and `capitals.json` carries Juneau and Honolulu.
There is intentionally **no `maxBounds`** clamping the viewport to CONUS — the
default center/zoom is a starting view, not a hard boundary.

### ZCTA source kind (true USPS vs approximation)

The ZIP/ZCTA overlay renders whatever tileset `VITE_ZCTA_TILES_URL` points at.
ZCTA boundaries are a Census **approximation** of USPS ZIP areas, not the true
USPS delivery geometry — so the toggle label names the configured source kind via
`VITE_ZCTA_SOURCE_LABEL` (default `"ZCTA approximation"`). To ship a true-USPS or
other ZIP tileset, provision it and set the label per
[`docs/zcta-tiles-setup.md`](./zcta-tiles-setup.md) (hosting the tileset is the
operator's responsibility; it is out of scope for hex-grid).
