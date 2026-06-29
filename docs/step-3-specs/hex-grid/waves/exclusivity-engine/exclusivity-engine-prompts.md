# Wave 3 — exclusivity-engine — per-ticket build prompts

Build in dependency order. One sequential wave writer; co-edited shared files (customers.ts, CustomerList.tsx, CustomerForm.tsx, index.css) are serialized by the depends_on chain. Full detail: the run-folder spec.md (24 ACs), adr.md (ADR-003, exact SQL), ui-spec-addendum.md.

---

## EX-T1 — Migration 0003 + conflict RPCs + RLS/spatial tests  ·  depends_on: []
**Files:** supabase/migrations/0003_exclusivity_engine.sql, src/lib/exclusivity.integration.test.ts, src/test/integration-setup.ts (EXTEND the existing CG-T10 harness — do not recreate)
**ACs:** AC-001..012  ·  **Gates:** db-migration-reviewer, security-auditor, performance-reviewer, architect-review

Follow 0001/0002 discipline literally (security invoker, pinned `search_path = public, pg_temp`, revoke public/anon + grant authenticated, REUSE — never redefine — auth_tenant_ids()/geocode_cache/site_geog_gist). Binding build order: (1) `alter table customer add column vertical text` (nullable) + `create index on customer(tenant_id, vertical)`; (2) idempotent backfill `update customer set vertical = attributes->>'vertical' where vertical is null and attributes ? 'vertical'`; (3) `create or replace view site_geo with (security_invoker = true)` keeping the W2 column order then APPENDING `s.exclusivity_radius_mi, s.is_zone_on, c.vertical` (join customer c on c.id = s.customer_id) — the invoker flag is the entire cross-tenant isolation mechanism, do NOT drop it; (4) the two RPCs; (5) grants.
- Do NOT add `exclusivity_radius_mi` (exists 0001:38). Do NOT touch `site.vertical` (superseded). No new RLS policy.
- `conflicts_at(p_geog geography, p_radius_mi numeric, p_vertical text, p_exclude_id uuid)` — `language sql stable security invoker set search_path = public, pg_temp` — returns (site_id, site_name, customer_id, customer_name, distance_mi, radius_mi). Predicate (ADR-003 §3): same-vertical, non-null vertical both sides, exclude self, `ST_DWithin(s.geog, p_geog, greatest(effectiveA, effectiveB)*1609.344)` with `greatest(...) > 0`; effective radius = `case when is_zone_on then coalesce(radius,0) else 0 end`. Pure-reports.
- `site_conflicts(p_site_id uuid)` wraps conflicts_at via lateral over the site's own geog/effective-radius/vertical, excluding self.
- Grants mirror place_site: revoke all from public; revoke execute from anon; grant execute to authenticated.
- Reversible (reverse order): drop site_conflicts; drop conflicts_at; recreate site_geo to the ADR-002 shape; drop column customer.vertical.
- Tests (RLS-scoped, two authenticated tenants): backfill seeds vertical + idempotent + null-stays-null (AC-002); site_geo exposes the 3 fields (AC-003); site_conflicts returns the typed row (AC-005); boundary (0.5,0.5)@0.9mi ⇒ empty, (1.0,0.5)@0.9mi ⇒ one (AC-008); cross-vertical ⇒ empty (AC-009); null-vertical ⇒ empty (AC-010); both-off ⇒ empty, (0,2) intruding ⇒ one (AC-011); two-tenant isolation + anon RPC denied (AC-012). Migration applies+reverses cleanly on a 0001+0002 baseline (AC-001/004/006/007).
- **Local apply needs a populated-safe path:** if `site` has rows, `supabase db reset` re-applies all migrations clean; the migration itself is additive/nullable.

---

## EX-T2 — Conflict seam + SiteGeo extension + updateSiteRadius  ·  depends_on: [EX-T1]
**Files:** src/lib/conflicts.ts, src/lib/customers.ts, src/lib/conflicts.test.ts
**ACs:** AC-013,014,015  ·  **Gates:** code-reviewer, architect-review

- `src/lib/conflicts.ts`: `findConflicts(point{lng,lat}, radiusMi|null, vertical|null, excludeId|null)` over `supabase.rpc('conflicts_at', …)` (EWKT `'SRID=4326;POINT(lng lat)'` as updateSiteLocation builds it) and `findSiteConflicts(siteId)` over `site_conflicts`; both return typed `Conflict[]` (`site_id, site_name, customer_id, customer_name, distance_mi, radius_mi`). These wrappers are the ONLY rpc call sites (AC-013).
- Extend `SiteGeo` (customers.ts:23) with `exclusivity_radius_mi: number|null`, `is_zone_on: boolean`, `vertical: string|null` — additive; tsc passes; sitePinsLayer unaffected (AC-014).
- `updateSiteRadius(siteId, mi|null)` — PostgREST update of `site.exclusivity_radius_mi` (RLS-scoped); 'Off' → null (AC-015).
- Tests (reuse two-tenant setup): findSiteConflicts typed rows; findConflicts empty for null vertical; updateSiteRadius round-trips (set→read via site_geo; Off→null).

---

## EX-T3 — Customer vertical picker (add + edit)  ·  depends_on: [EX-T2]
**Files:** src/components/CustomerForm.tsx, src/components/CustomerList.tsx, src/lib/customers.ts, src/index.css
**ACs:** AC-019  ·  **Gates:** code-reviewer, accessibility-auditor, ui-review, architect-review

- Replace the W2 free-text 'Vertical' input on CustomerForm with a controlled native `<select>` (useId label 'Vertical'). Starter value set, lowercase tokens in `customer.vertical`: gas, grocery, pharmacy, qsr, fitness, automotive, banking, hotel + empty 'Select vertical…' (`""`→null). Wire through createCustomerWithSites into the `customer.vertical` COLUMN, not attributes (AC-019; `git grep 'attributes.*vertical' CustomerForm.tsx` → nothing).
- CustomerRow 'Edit vertical' reveal (mirror SiteRow edit-address + A11Y-001 focus-on-reveal): view shows current vertical + 'Edit vertical' button; reveal `.field-inline` with the `<select>` + Save/Cancel; Save → new `updateCustomerVertical(customerId, token|null)` (customers.ts) → onChanged(). Null vertical → 'No vertical set' + muted hint 'Set a vertical to enable conflict detection.' CustomerList customer query must select the new column.
- A11y: useId labels, native select/button, role=alert on error, aria-live 'Saving vertical…', :focus-visible intact. index.css: reuse .field/.field-inline/.btn-secondary/.helper-text, literal hex only.

---

## EX-T4 — Per-site radius picker in SiteRow  ·  depends_on: [EX-T2, EX-T3]
**Files:** src/components/CustomerList.tsx, src/index.css
**ACs:** AC-018  ·  **Gates:** code-reviewer, accessibility-auditor, ui-review

- Persistent (view-mode) per-site radius `<select>` in each SiteRow `.site-item` after geo-status, in a `.radius-picker` wrapper. useId label 'Zone radius'. Options/values: 'Off (no zone)'→`""`→null; '0.5 mi'→"0.5"; … '3 mi'→"3". Init from site.exclusivity_radius_mi (null→"").
- onChange → updateSiteRadius(site.id, mi|null) → onChanged() (map redraws/recolors). In-flight: disable + aria-live 'Saving radius…'; error → role=alert .form-error. Off ⇒ null ⇒ no circle (EX-T5 filter) + 'No zone' status, but site can still be a Conflict. Do NOT expose is_zone_on.
- index.css `.radius-picker { display:inline-flex; align-items:center; gap:0.5rem }`, reuse `.field select`, literal hex, :focus-visible inherited.

---

## EX-T5 — Zone circles + conflictIds + MapShell mount + zone-status  ·  depends_on: [EX-T2, EX-T4]
**Files:** src/components/siteZonesLayer.ts, src/components/MapShell.tsx, src/App.tsx, src/components/CustomerList.tsx, src/index.css
**ACs:** AC-021,022,024  ·  **Gates:** code-reviewer, accessibility-auditor, ui-review, performance-reviewer

- `siteZonesLayer(sites, conflictIds:Set<string>)` → deck.gl ScatterplotLayer key 'site-zones'. data = located sites with effective zone (lat/lng set, is_zone_on, radius>0); getPosition [lng,lat]; radiusUnits:'meters'; getRadius `radius_mi*1609.344`; stroked+filled, pickable:false. Color on conflictIds.has(d.id): clear → fill [21,88,176,38]/line [21,88,176,200] w1; conflict → fill [176,0,32,46]/line [176,0,32,220] w2 (thicker stroke = non-color cue). RGBA literals only.
- Wire-to-consumer (AC-021): MapShell mounts BOTH layers `overlay.setProps({ layers: [siteZonesLayer(sites, conflictIds), sitePinsLayer(sites)] })` (zones under pins); MapShell gains `conflictIds` prop; rebuild on sites/conflictIds change.
- conflictIds derivation (AC-022) in App.tsx (owns lifted sites): after fetching sites in reload()/initial load, derive `Set<string>` of every site_id appearing in any findSiteConflicts result (whole-tenant pass, on data change NOT per frame); pass to MapShell + CustomerList. (App.tsx = amend-planned-files.) In-flight → neutral 'Checking…', never a false 'Exclusive'.
- zone-status in SiteRow (AC-022): `.zone-status zone-status--{off|clear|conflict}` word+glyph (glyph aria-hidden): null/off → 'No zone' ○ #555; set & clear → 'Exclusive {mi} mi' ✓ #137333; in conflictIds → 'Conflict (N)' ⚠ #b00020. Conflicting row shows neighbor detail in .helper-text ('Conflicts with {customer} — {site} ({dist} mi).').
- AC-024 passive recolor: radius change → onChanged → App re-derives conflictIds → redraw, NO modal. index.css `.zone-status*` cloned from .geo-status (gap .5rem, .875rem, 600), literal hex.

---

## EX-T6 — Warn-with-confirm conflict dialog on add + move  ·  depends_on: [EX-T2, EX-T3, EX-T5]
**Files:** src/components/CustomerForm.tsx, src/components/CustomerList.tsx, src/index.css
**ACs:** AC-016,017,020,023,024  ·  **Gates:** code-reviewer, accessibility-auditor, ui-review, architect-review

- Reuse the W2 A11Y-002 native `<dialog>` confirm verbatim (showModal, real buttons, ESC cancels, onClose restores focus to trigger). Heading 'Exclusivity conflict' (aria-labelledby via useId). Body: context line + `.conflict-list` ul, one li per conflict: '{customer} — {site} · {dist} mi · {vertical-label}'. Buttons: add → 'Add anyway' (.btn-danger) + 'Cancel'; move → 'Move anyway' (.btn-danger) + 'Cancel'. DEFAULT FOCUS ON CANCEL; ESC=Cancel=abort; override is non-blocking (always persists on proceed).
- Wire add (AC-016): CustomerForm, after geocode resolves a point and BEFORE place_site, `findConflicts(point, newRadius??null, customerVertical, null)`. Non-empty → dialog; 'Add anyway' → place_site + W2 outcome report; 'Cancel' → no persist, .helper-text 'Add cancelled — conflict not overridden'. No-vertical add ⇒ empty ⇒ no dialog. Multi-site add ⇒ check per prospective site, ONE consolidated dialog; 'Add anyway' proceeds all, 'Cancel' aborts the submit. (`git grep findConflicts CustomerForm.tsx`.)
- Wire move (AC-017): CustomerList 'Save location' computes the new point, `findConflicts(point, thisSite.exclusivity_radius_mi, thisCustomer.vertical, thisSite.id)` (SELF excluded) BEFORE updateSiteLocation. Conflicts → dialog; 'Move anyway' → updateSiteLocation + onChanged(); 'Cancel' → stay in move mode, no write.
- AC-020 in-flight: 'Checking exclusivity…' + disable trigger. AC-024: never hard-block. AC-023 full a11y across all new controls (useId labels, native select/button, role=alert/aria-live, focus order, non-color-alone, :focus-visible, neutral 'Checking…'). index.css `.conflict-list` (item gap .25rem; dialog max-width 28rem), literal hex.
