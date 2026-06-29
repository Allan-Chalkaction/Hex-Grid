# Feature Spec: Wave 3 — Exclusivity Engine

**Status:** Draft
**Author:** AI-assisted (pm-spec agent, integrator)
**Date:** 2026-06-28
**Slug:** exclusivity-engine
**Ticket key:** HGW-3

## Summary
Wave 3 is the product's core value: per-site exclusivity zones drawn on the map and same-vertical conflicts flagged on add/move. A `0003` migration promotes **vertical to a real `customer.vertical` column** (the conflict key, backfilled idempotently from `attributes->>'vertical'`), extends the `site_geo` view with the zone-render fields, and adds two `security_invoker` conflict-detection RPCs (`conflicts_at` primitive + `site_conflicts` wrapper) that **pure-report** — the UI owns disposition. The default disposition is **WARN-with-confirm** (non-blocking override) reusing the W2 native `<dialog>`. Zones render as geodesically-accurate translucent **circles** (deck.gl `ScatterplotLayer`, `radiusUnits:'meters'`); H3 hex-fill, hard-block enforcement, and area-saturation are deferred to Wave 4.

## User Stories
- As a tenant member, I want to set a per-site exclusivity radius (off / 0.5 / 1 / 1.5 / 2 / 2.5 / 3 mi) so that each site claims a protected territory drawn on the map.
- As a tenant member, I want to assign a customer's vertical from a controlled list so that conflict detection knows which brands compete (gas-vs-gas conflicts; gas-vs-grocery does not).
- As a tenant member, I want to be warned when adding or moving a site into a same-vertical neighbor's exclusivity zone — with the conflicting brands/sites/distances named — so that I can make an informed decision, but still proceed if I choose (non-blocking).
- As a tenant member, I want conflicting zones recolored on the map and a persistent, screen-reader-readable conflict status in the site list so that I can see exclusivity state without opening a modal.
- As a tenant member, I must never see another tenant's sites surfaced through conflict detection, so that tenant isolation holds across the new RPCs.

## Acceptance Criteria

### Schema & migration (0003)

- [ ] **AC-001.** Substantive: a real `customer.vertical text` column exists (nullable), promoted out of `customer.attributes`; a supporting index `customer(tenant_id, vertical)` exists to serve the same-vertical join filter. The W1-reserved `site.vertical` column is left untouched (superseded debt, not dropped). Verification: `0003` applies cleanly to a 0001+0002 baseline; `\d customer` shows `vertical text` and the composite index; `git grep -n 'site.*drop column vertical\|alter table site' supabase/migrations/0003_*.sql` returns nothing touching `site.vertical`.
- [ ] **AC-002.** Substantive: the migration idempotently backfills `customer.vertical` from `attributes->>'vertical'` only where a value is present and `vertical` is still null, so re-running it never clobbers a manually-set value. Verification: integration test seeds a customer with `attributes = '{"vertical":"gas"}'`, runs the backfill statement, asserts `vertical = 'gas'`; a second run is a no-op; a customer with no `attributes.vertical` stays null.
- [ ] **AC-003.** Substantive: `site_geo` is recreated `create or replace view ... with (security_invoker = true)` (the invoker flag PRESERVED — load-bearing cross-tenant isolation) extended to carry `exclusivity_radius_mi`, `is_zone_on`, and `c.vertical` (joined from `customer`), keeping the W2 column order then appending. Existing readers (`sitePinsLayer`) are additive-safe. Verification: `git grep -n 'security_invoker' supabase/migrations/0003_*.sql` returns the view; a `site_geo` select returns the three new fields; the two-tenant RLS test (AC-012) passes through `site_geo`.
- [ ] **AC-004.** Substantive: a `conflicts_at(p_geog geography, p_radius_mi numeric, p_vertical text, p_exclude_id uuid)` RPC exists — `language sql stable security invoker set search_path = public, pg_temp` — implementing the bidirectional `max(A.radius, B.radius)` point-in-zone predicate via `ST_DWithin(geography, geography, meters)` with `1 mi = 1609.344 m`, effective radius `case when is_zone_on then coalesce(exclusivity_radius_mi,0) else 0 end`, within-vertical only (`p_vertical is not null AND c.vertical = p_vertical`), `greatest(...) > 0` (both-off ⇒ no conflict), and `p_exclude_id` self-exclusion. It pure-reports (never blocks an insert). Verification: code review against ADR-003 §Decision 3 SQL; the spatial unit tests AC-008..AC-011 pass; `git grep -n 'security invoker' supabase/migrations/0003_*.sql` shows it on the function.
- [ ] **AC-005.** Substantive: a `site_conflicts(p_site_id uuid)` convenience wrapper (same `security invoker` + pinned `search_path`) reports conflicts for an already-persisted site by `cross join lateral conflicts_at(...)` over the site's own geog/effective-radius/vertical, excluding self. Verification: an integration test persists two same-vertical sites within the max radius, calls `site_conflicts(siteA)`, and asserts site B is returned with `distance_mi`, `radius_mi`, `customer_name`, `site_name`.
- [ ] **AC-006.** Substantive: both RPCs follow the 0001/0002 ACL-tightening exactly — `revoke all from public; revoke execute from anon; grant execute to authenticated` — and reuse (never redefine) `auth_tenant_ids()`, the `geocode_cache` table, and the `site_geog_gist` index. No new table RLS policy is added (the existing `site`/`customer` policies scope the reads via `security invoker`). Verification: `git grep -n 'grant execute' supabase/migrations/0003_*.sql` shows both functions granted to authenticated only; `0003` contains no `create ... auth_tenant_ids` and no `create policy`.
- [ ] **AC-007.** Substantive: `0003` is forward-only, all changes additive/nullable, zero-downtime, and reversible in reverse dependency order (`drop function site_conflicts; drop function conflicts_at; create or replace view site_geo` back to the ADR-002 shape; `alter table customer drop column vertical`). It does **not** add `exclusivity_radius_mi` (it already physically exists — `0001:38`) and needs no radius backfill (null = off). Build order is BINDING: `customer.vertical` (+index) → backfill → `create or replace view site_geo` → RPCs → grants. Verification: the migration applies and reverses cleanly on a 0001+0002 baseline; `git grep -n 'add column exclusivity_radius_mi' supabase/migrations/0003_*.sql` returns nothing.

### Conflict semantics (RLS-scoped integration tests)

- [ ] **AC-008.** Substantive: the `max(A.radius, B.radius)` threshold is correct at the boundary — a same-vertical pair at 0.9 mi apart with radii (0.5, 0.5) does NOT conflict (neither sits inside the other's 0.5 mi territory); the same pair with radii (1.0, 0.5) DOES conflict (the 1.0 mi territory reaches the neighbor). Verification: vitest integration test seeds both pairs RLS-scoped and asserts `conflicts_at` returns empty for (0.5,0.5) and one row for (1.0,0.5).
- [ ] **AC-009.** Substantive: cross-vertical sites never conflict — two sites 0.1 mi apart whose customers have different verticals (e.g. `gas` vs `grocery`) return no conflict. Verification: vitest integration test seeds the cross-vertical pair and asserts `conflicts_at`/`site_conflicts` return empty.
- [ ] **AC-010.** Substantive: a null vertical never conflicts — a site whose customer `vertical is null` (or a prospective `p_vertical = null`) returns no conflict regardless of distance/radius. Verification: vitest integration test seeds a null-vertical customer adjacent to a populated one and asserts empty results both directions.
- [ ] **AC-011.** Substantive: off/zero-effective-radius semantics are correct — two same-vertical sites both with radius off (null/0 or `is_zone_on=false`) never conflict (`greatest(...) = 0`); but an off-radius site (0) that sits inside an on-neighbor's zone (e.g. neighbor radius 2 mi) IS flagged (it intrudes the neighbor's territory). Verification: vitest integration test asserts both-off ⇒ empty, and (0, 2) intruding ⇒ one conflict.
- [ ] **AC-012.** Substantive: tenant isolation holds for the new RPCs — tenant A's `conflicts_at`/`site_conflicts` never return tenant B's sites (a same-vertical B site geographically adjacent to an A site does not appear), and an unauthenticated RPC call is denied. Verification: two-tenant vitest integration test (same shape as ADR-001 AC-003) asserts B's sites never surface in A's results; an anon RPC call returns denied/empty.

### Conflict seam + write paths (TypeScript)

- [ ] **AC-013.** Substantive: a `src/lib/conflicts.ts` seam exports a typed `findConflicts(point, radiusMi, vertical, excludeId)` wrapper over `supabase.rpc('conflicts_at', ...)` and a `findSiteConflicts(siteId)` wrapper over `supabase.rpc('site_conflicts', ...)`, each returning a typed `Conflict[]` (`{ site_id, site_name, customer_id, customer_name, distance_mi, radius_mi }`); consumers never call `supabase.rpc` directly. The `geography` param is passed as EWKT `'SRID=4326;POINT(lng lat)'` (matching `updateSiteLocation`, customers.ts:169). Verification: `git grep -n 'export.*findConflicts\|export.*findSiteConflicts' src/lib/conflicts.ts`; `git grep -n "rpc('conflicts_at'\|rpc('site_conflicts'" src/` shows calls only inside `conflicts.ts`.
- [ ] **AC-014.** Substantive: the `SiteGeo` interface (`src/lib/customers.ts:23`) gains `exclusivity_radius_mi: number | null`, `is_zone_on: boolean`, and `vertical: string | null`; existing readers are unaffected (additive). Verification: `git grep -n 'exclusivity_radius_mi\|is_zone_on\|vertical' src/lib/customers.ts` shows the three fields on `SiteGeo`; `tsc` passes.
- [ ] **AC-015.** Substantive: a `updateSiteRadius(siteId, mi | null)` helper writes `site.exclusivity_radius_mi` via PostgREST update on `site` (RLS-scoped by `site_tenant_update`); the picker's "Off" writes `null`. Verification: `git grep -n 'export.*updateSiteRadius' src/lib/customers.ts`; an integration test sets a radius then reads it back via `site_geo`, and Off writes null.
- [ ] **AC-016.** Substantive (wire-to-consumer): `findConflicts` is actually invoked by the **add** path — the `CustomerForm` add flow calls it with the prospective point/radius/vertical BEFORE `place_site`, and on a non-empty result presents the warn dialog; it is not merely defined. A no-vertical add returns empty ⇒ no dialog ⇒ add proceeds. Verification: `git grep -n 'findConflicts' src/components/CustomerForm.tsx` shows the call site AND the add-flow test asserts `findConflicts` is called before persistence and that the dialog gates the override.
- [ ] **AC-017.** Substantive (wire-to-consumer): `findConflicts` is actually invoked by the **move** path — `CustomerList`'s "Save location" computes the new point and calls `findConflicts(point, thisSite.radius, thisCustomer.vertical, thisSite.id)` (self excluded via `p_exclude_id`) before `updateSiteLocation`; conflicts → dialog → "Move anyway" proceeds, "Cancel" leaves the site unmoved. Verification: `git grep -n 'findConflicts' src/components/CustomerList.tsx` shows the call site AND the move test asserts self-exclusion (a site never conflicts with itself) and that Cancel writes nothing.

### UI — pickers, dialog, rendering, surfacing

- [ ] **AC-018.** Substantive: each `CustomerList` `SiteRow` renders a persistent (view-mode) per-site radius `<select>` inside a `.radius-picker` wrapper with a real `useId`-associated `<label>Zone radius</label>` and the eight locked options (Off→`""`→null, 0.5/1/1.5/2/2.5/3 mi); on change it calls `updateSiteRadius` then `onChanged()` so the map redraws; in-flight it disables + shows an `aria-live="polite"` "Saving radius…" note, on error a `role="alert" .form-error`. Verification: manual run — change radius → zone circle redraws; Off removes the circle; screen reader announces the label; `git grep -n 'radius-picker' src/index.css src/components/CustomerList.tsx`.
- [ ] **AC-019.** Substantive: the customer vertical is a controlled-value `<select>` (NOT free text) — replacing the W2 free-text vertical input on `CustomerForm` (lines ~152–160) and added as an "Edit vertical" reveal on `CustomerList` `CustomerRow` (mirroring the SiteRow edit-address pattern, focus-on-reveal). The value set is the 8-item starter list stored as lowercase tokens in `customer.vertical` (gas/grocery/pharmacy/qsr/fitness/automotive/banking/hotel; empty `""` → null). A customer with null vertical shows "No vertical set" + the muted hint "Set a vertical to enable conflict detection." Verification: manual — set a vertical on add and on an existing customer → persists to `customer.vertical`; `git grep -n 'attributes.*vertical' src/components/CustomerForm.tsx` returns nothing (no free-text vertical write remains).
- [ ] **AC-020.** Substantive: on add/move with conflicts, a native `<dialog>` warn (reusing the W2 A11Y-002 `requestDelete`/`confirmDelete` pattern verbatim, `className="confirm-dialog"`) opens with heading "Exclusivity conflict" (`aria-labelledby`), a `.conflict-list` `<ul>` naming each conflicting site (`{customer_name} — {site_name} · {distance_mi} mi · {vertical}`, distance to one decimal), and `.row-actions` of "Add anyway"/"Move anyway" (`.btn-danger`, the override) + "Cancel" (`.btn-secondary`). **Default focus on Cancel**; ESC = Cancel = abort (nothing persists); `onClose` returns focus to the trigger. The override is **non-blocking** — proceeding always persists. Verification: manual + a11y review — Tab cycles within the dialog, ESC aborts, "Add anyway" persists despite conflict; default focus is Cancel; `git grep -n 'confirm-dialog\|conflict-list' src/index.css`.
- [ ] **AC-021.** Substantive (wire-to-consumer): a new `siteZonesLayer(sites, conflictIds)` factory (mirroring `sitePinsLayer.ts`) returns a deck.gl `ScatterplotLayer` keyed `'site-zones'` (`radiusUnits:'meters'`, `getRadius: d => d.exclusivity_radius_mi * 1609.344`, stroked+filled, `pickable:false`) drawing only located sites with an effective zone (`lat/lng != null && is_zone_on && exclusivity_radius_mi > 0`), and it is **mounted into `MapShell`** below the pins (`overlay.setProps({ layers: [siteZonesLayer(...), sitePinsLayer(...)] })`). Non-conflict zones use `[21,88,176]` (fill α38 / stroke α200 w1); conflict zones use `[176,0,32]` (fill α46 / stroke α220 **w2** — thicker stroke is the non-color map cue). Verification: `git grep -n 'siteZonesLayer\|ScatterplotLayer' src/components/MapShell.tsx src/components/siteZonesLayer.ts` shows the factory + mount in the real render path; manual — a 1 mi zone draws a circle of radius 1609.344 m; a conflicting zone recolors red.
- [ ] **AC-022.** Substantive: conflict state is **derived from the RPC, never a view column** — on data change the UI computes `conflictIds: Set<string>` (via `site_conflicts` for a changed site and/or an on-demand whole-tenant pass), recomputed on data change not per frame; each `SiteRow` shows a `.zone-status` indicator carrying the **non-color-alone** signal (word+glyph+color, mirroring `.geo-status`): "No zone" (`○`, `#555`) / "Exclusive {mi} mi" (`✓`, `#137333`) / "Conflict ({N})" (`⚠`, `#b00020`), the word being real SR-announced text and the glyph `aria-hidden`; a conflicting row also renders persistent neighbor detail in `.helper-text` (same facts as the dialog). Verification: `git grep -n 'zone-status' src/index.css src/components/CustomerList.tsx`; manual — a conflict shows "Conflict (1)" + neighbor line in the list with the map canvas color as reinforcement only; no conflict-state column appears in `site_geo`.
- [ ] **AC-023.** Substantive: every new control carries the W1/W2 a11y contract — `useId()` label association on both `<select>`s, real `<label>`/`<button>` (no `<div onClick>`, no custom segmented control), `role="alert"`/`aria-live="polite"` for write/check status, native focus order, conflict signaled non-color-alone, and the global `:focus-visible` outline left intact. Conflict computation in-flight shows a neutral "Checking…" (`#555`, `aria-live`) rather than a false "Exclusive". Contrast: `#b00020`/`#137333`/`#555` clear AA (≥4.5:1) on white; map strokes `#1558b0`/`#b00020` clear the 3:1 graphical bar. Verification: accessibility review against the W2 north-star files; contrast checks pass WCAG 2.2 AA.
- [ ] **AC-024.** Substantive: the warn is scoped to add/move only and is non-blocking — a **radius change** recolors zones passively (recompute `conflictIds` + redraw, no modal); the add/move dialog never hard-blocks; `place_site`/`updateSiteLocation` still persist on override. An Off/null-radius site draws no circle (filtered from layer `data`) but can still appear as "Conflict" if it intrudes a neighbor's zone. Verification: manual — a radius change opens no dialog yet recolors; "Add anyway" inserts the site; an Off site shows no circle but its pin remains and it can carry a Conflict status.

## Scope

### In Scope (Phase 1)
- Migration `0003`: `customer.vertical` column (+ `customer(tenant_id, vertical)` index) + idempotent jsonb backfill; `create or replace view site_geo` (security_invoker preserved) extended with `exclusivity_radius_mi`, `is_zone_on`, `vertical`; the `conflicts_at` + `site_conflicts` `security_invoker` RPCs + ACL grants.
- Per-site exclusivity-radius `<select>` (off/0.5/1/1.5/2/2.5/3 mi) writing `site.exclusivity_radius_mi` via `updateSiteRadius`.
- Customer vertical controlled-value `<select>` (write path on add + edit) — required so conflicts ever fire.
- `src/lib/conflicts.ts` seam (`findConflicts` / `findSiteConflicts`), pure-reporting RPC consumers.
- WARN-with-confirm (non-blocking) native `<dialog>` on add/move, naming conflicting brands/sites/distances.
- Circle zone rendering (`siteZonesLayer` deck.gl `ScatterplotLayer`, meters) mounted under the pins in `MapShell`, recolored on conflict.
- Conflict surfacing in `CustomerList` (`.zone-status` word+glyph+color + neighbor detail), derived from the RPC.
- `SiteGeo` type extension.

### Out of Scope (Deferred to Wave 4)
- **H3 hex-fill zone rendering** — W4's signature payload (area-saturation); imports `h3-js` + per-viewport binning. W3 ships meter-accurate circles (viz == the geodesic `ST_DWithin` semantic). Interim: circles are the zone geometry.
- **Hard-block enforcement** on conflict — requires server-side enforcement in `place_site`/update to avoid TOCTOU and would freeze policy into persistence. W3 = WARN-with-confirm; the RPCs stay pure-reporting so a later block can be layered without re-architecting. (Carried-forward follow-up.)
- **Area-saturation / whole-area coverage analytics** — W4.
- **Dropping the dead `site.vertical` column** — superseded by `customer.vertical`; left in place (documented debt; a later chore may drop it).
- **Exposing `is_zone_on` as a UI toggle** — the predicate folds it in; W3's "Off" is expressed via `exclusivity_radius_mi = null`. `is_zone_on` remains a separate master toggle (default true) with no W3 control.

### Files in scope
- `supabase/migrations/0003_exclusivity_engine.sql` — *create*
- `src/lib/conflicts.ts` — *create*
- `src/components/siteZonesLayer.ts` — *create*
- `src/lib/customers.ts` — *modify* (extend `SiteGeo`; add `updateSiteRadius`)
- `src/components/CustomerForm.tsx` — *modify* (controlled vertical `<select>` replacing free-text; add-flow `findConflicts` + warn dialog)
- `src/components/CustomerList.tsx` — *modify* (radius picker + zone-status in `SiteRow`; vertical edit reveal in `CustomerRow`; move-flow `findConflicts` + warn dialog; conflictIds derivation)
- `src/components/MapShell.tsx` — *modify* (mount `siteZonesLayer` under `sitePinsLayer`; rebuild on `sites`/`conflictIds` change)
- `src/index.css` — *modify* (new `.radius-picker`, `.zone-status*`, `.conflict-list` semantic classes; reuse existing literal-hex palette)

## Technical Notes

### Existing Patterns to Reuse
- Migration discipline (`security invoker`, pinned `search_path`, revoke-anon/grant-authenticated, reuse `auth_tenant_ids()`) — `supabase/migrations/0001`/`0002`; `place_site` is the RPC template.
- `security_invoker` view as the entire cross-tenant isolation mechanism — `site_geo` in `0002` (ADR-002).
- Pure-reporting RPC + EWKT `geography` cast — mirror `updateSiteLocation` (customers.ts:169) for the `conflicts_at` point param.
- deck.gl layer factory + reactive overlay mount — `sitePinsLayer.ts` + `MapShell.tsx` (`overlay.setProps`); `siteZonesLayer` is a second layer below the pins.
- Native `<dialog>` confirm with `onClose` focus return — `CustomerList` `requestDelete`/`confirmDelete` (W2 A11Y-002); copy verbatim for the warn dialog.
- Form a11y (`useId` label, `role="alert"`, disabled-with-label-swap, focus-on-reveal) — `CustomerForm`/`CustomerList` (W2 A11Y-001).
- Plain semantic CSS + literal hex (NO Tailwind/tokens) — `src/index.css` `.geo-status*`/`.field`/`.confirm-dialog`.

### New Components Needed
- `src/lib/conflicts.ts` (RPC seam), `src/components/siteZonesLayer.ts` (zone circles). Everything else extends existing files.

### Data Lifecycle

| Entity | Source | Created By | Management Interface | Status |
|--------|--------|------------|---------------------|--------|
| `customer.vertical` | new column (0003) + idempotent backfill from `attributes->>'vertical'` | tenant user (picker) + migration (seed) | controlled `<select>` on `CustomerForm` (add) + `CustomerList` `CustomerRow` (edit) | NEW write path — in scope |
| `site.exclusivity_radius_mi` | existing column (0001:38, reserved) | tenant user (radius picker) | per-site `<select>` in `CustomerList` `SiteRow` via `updateSiteRadius` | existing column, NEW write path — in scope |
| conflict results | derived (RPC over existing `site`/`customer`) | system (RPC, on data change) | read via `findConflicts`/`findSiteConflicts`; rendered as `conflictIds` + `.zone-status` | in-scope (no table) |
| `site.geog` | existing (W2 add/move) | tenant user | W2 add/move paths (unchanged) | exists |
| `site.is_zone_on` | existing (0001:39, default true) | system default | NOT exposed in W3 (predicate folds it in) | exists (no W3 control) |

Every read entity has a concrete write path — `customer.vertical` (picker + backfill), `exclusivity_radius_mi` (radius picker), conflict results (RPC over existing tables). Read/write symmetry holds (architect: no blockers).

### Database Changes
- `0003_exclusivity_engine.sql`: `customer.vertical text` + `customer(tenant_id, vertical)` index; idempotent backfill; `create or replace view site_geo` (security_invoker = true) extended with the three render fields; `conflicts_at` + `site_conflicts` `security_invoker` RPCs (pinned `search_path`); revoke-public/anon + grant-authenticated on both.
- **No new table RLS policy** — the existing `site`/`customer` policies (0001:125-140, 0002:53-68) scope the RPC reads via `security invoker`. `exclusivity_radius_mi` is NOT added (exists). `site.vertical` untouched.
- Data classification: `customer.vertical` is tenant-private business data (per-tenant RLS). Conflict results are tenant-scoped by construction (security_invoker over RLS).
- Build order (BINDING): `customer.vertical` (+index) → backfill → `site_geo` recreate → RPCs → grants. Forward-only; reversible in reverse order.

### API / RPCs
- `conflicts_at(p_geog geography, p_radius_mi numeric, p_vertical text, p_exclude_id uuid)` — prospective-point primitive (add + move preview).
- `site_conflicts(p_site_id uuid)` — wrapper for an already-persisted site (list/move surfaces).
- Both `language sql stable security invoker set search_path = public, pg_temp`; exact SQL in ADR-003 §Decision 3.

### Security Considerations
- **`security invoker` is mandatory and load-bearing on both RPCs and the view** — a `security definer` slip leaks cross-tenant conflict data. The two-tenant test (AC-012) is required; security-auditor + db-migration-reviewer gate the migration.
- ACL tightening mirrors `place_site`/`auth_tenant_ids()` exactly (revoke public/anon, grant authenticated only) — Supabase default-ACL must be tightened.
- No anon policy added (unauthenticated denied by construction, W1 posture).
- Pinned `search_path` on both functions.

### Accessibility Requirements
- WCAG 2.2 AA: `useId()` label on both `<select>`s; conflict signaled **non-color-alone** via the `.zone-status` word+glyph (word is real SR text, glyph `aria-hidden`) — map color + thicker conflict stroke are reinforcement only (the map canvas is `role="application"`, a11y scoped to the chrome — W2 A11Y-011).
- Native `<dialog>` warn: focus trap + ESC=Cancel + default focus on Cancel (so a reflexive Enter never silently overrides) + `onClose` focus return.
- `aria-live="polite"` for radius/vertical/conflict-check in-flight states; `role="alert"` for errors; neutral "Checking…" while conflicts compute (never a false "Exclusive").
- Contrast: text `#b00020` (~7:1) / `#137333` (~5.9:1) / `#555` (~7.5:1) clear AA; map strokes `#1558b0`/`#b00020` clear the 3:1 graphical-object bar; `#1a73e8` focus ring is the 3:1 non-text component color — do not weaken it.

### Performance Considerations
- `site_geog_gist` (0001:47) serves `ST_DWithin`; the new `customer(tenant_id, vertical)` index serves the same-vertical join; `site_customer_id_idx` (0002:110) serves the join. Single add/move check = one GIST query (negligible).
- Whole-tenant zone coloring is pairwise but bounded (GIST + within-tenant + same-vertical), computed on data change, **never per frame** (deck.gl is GPU-instanced). Acceptable to ~10k sites/tenant. If EXPLAIN shows a seq scan at scale, pre-filter by the fixed picker max (`3 * 1609.344` m) then exact-filter `GREATEST()` — performance-reviewer confirms the plan.

## Open questions / assumptions
- **Vertical value set** — Assumption: the 8-item starter list (gas/grocery/pharmacy/qsr/fitness/automotive/banking/hotel) stored as lowercase tokens; the column stays `text` so it can grow without a migration. Confirm the exact list at build.
- **Whole-tenant vs per-site conflict coloring** — Assumption: derive `conflictIds` from `site_conflicts` for a changed site (add/move) plus an on-demand whole-tenant pass for full initial coloring; recompute on data change only. Exact trigger cadence set at build.
- **Multi-site add (repeatable `CustomerForm` rows)** — Assumption: one consolidated dialog grouping conflicts under each prospective site; "Add anyway" proceeds with all, "Cancel" aborts the whole submit (UI-spec Deviation Log).
- **`GREATEST()` index usage** — Assumption: `ST_DWithin` remains index-aware with the dynamic threshold; verify via EXPLAIN, fall back to fixed-max pre-filter if not.

## ADR alignment

| ADR | Cited in | Operationalized by | Divergence (if any) | Rationale |
|---|---|---|---|---|
| ADR-003 (Wave 3 — within-vertical, per-site-radius conflict detection; security_invoker RPC; circle-zone render) | architect / manifest | AC-001..AC-024 | none | spec implements the `customer.vertical` promotion + backfill, the `max(A.radius,B.radius)` predicate, the two `security_invoker` RPCs, the extended `site_geo`, circle rendering, and warn-with-confirm exactly as decided |
| ADR-002 (Wave 2 — customer/site model, security_invoker view, API-first geo) | architect / ADR-003 | AC-003 (view recreate preserves invoker), AC-013 (EWKT cast), AC-015 (PostgREST radius write) | none | extends the proven seam additively; readers unaffected |
| ADR-001 (multi-tenant foundation) | architect / ADR-003 | AC-006 (reuse `auth_tenant_ids()`, ACL tightening), AC-012 (RLS isolation), no new policy | none | conflict reads inherit tenant isolation via security_invoker over the W1 RLS |
| cto-advisor (GO + SIMPLIFY) | cto-evaluation | Out of Scope (H3 hex-fill → W4; warn-default not block; circles-only) | none | SIMPLIFY folded into scope verbatim |

## Dependencies
- **Wave 1** (hex-grid-foundation) — shipped & merged: `site.geog` + `site_geog_gist`, `site.exclusivity_radius_mi`/`site.vertical`/`site.is_zone_on` reserved columns, `auth_tenant_ids()`, per-table RLS, map shell (deck.gl/MapLibre).
- **Wave 2** (customers-geocoding) — shipped & merged: `customer` table, `site.customer_id`, `site_geo` view, `place_site` RPC, `createCustomerWithSites`/`updateSiteLocation` write paths, `CustomerForm`/`CustomerList` UI, `sitePinsLayer` + `MapShell` reactive overlay, `.geo-status`/`.field`/`.confirm-dialog` CSS, `customer.attributes.vertical` free-text (superseded by `customer.vertical` this wave).
- No new npm dependency (H3/`h3-js` deferred to W4).
- Supabase PostgREST + Postgres/PostGIS runtime.

## Carried-forward follow-ups (deferred)
- **Hard-block enforcement** (server-side, in `place_site`/update) — deferred; requires TOCTOU-safe server enforcement. The pure-reporting RPCs are designed so this can layer on later without re-architecting.
- **Drop dead `site.vertical`** — documented debt; later chore.
- **H3 hex-fill / area-saturation** — Wave 4.
