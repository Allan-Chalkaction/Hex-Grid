# Code Review — Wave 2 (customers-geocoding)

**Verdict: REQUEST_CHANGES** · iteration 1 · scope: `git diff main..HEAD` (CG-T1..CG-T8), 13 source files.

The migration and RLS surface are excellent (`customer` mirrors `site_tenant_*`, `site_geo` is `security_invoker`, `place_site` is `security invoker`, empty-site guard + reversal notes present, `auth_tenant_ids()`/`geocode_cache` reused not redefined — AC-001..005, AC-018 satisfied). Edge Function is cache-first, JWT-forwarded, ignores client coords, caps batch/length, never echoes stack traces. Two correctness bugs + a test-coverage gap block merge.

## CR-001 — `upsertCustomer` silently wipes existing customer `attributes` on every re-import/re-add — HIGH (blocking) · `_criterion_match_: none`
`src/lib/customers.ts:71-79`; consumed `csvImport.ts:208`, `customers.ts:186`.
PostgREST merge-duplicates upsert sets every payload column incl. `attributes` (defaults `{}`). Re-importing/re-adding an existing customer overwrites its `attributes` to `{}` — silent loss of brand metadata (e.g. vertical). Contradicts AC-017 find-or-create intent.
**Disposition: APPLY.** Make dedup non-destructive: omit `attributes` from upsert when empty, or select-by-`(tenant_id,name)` first and never update attributes from the dedup path. Add regression test.

## CR-002 — Empty lat/lng coerce to `0,0` and save silently — MEDIUM (blocking) · `_criterion_match_: none`
`CustomerForm.tsx:301-306` (`saveManual`), `CustomerList.tsx:234-239` (`saveMove`).
`Number('')===0` and `Number.isFinite(0)===true`, so empty fields pass validation → site persisted to `(0,0)`. Defeats the AC-012 manual-coords recovery. `saveMove` pre-fills empty for un-located sites → easy mis-save.
**Disposition: APPLY.** Guard empty/whitespace before coercion (`lat.trim()===''`) or use `parseFloat`; range-validate lat∈[-90,90], lng∈[-180,180].

## CR-004 — Mandated verification tests absent, incl. the "Critical" two-tenant RLS test — HIGH (blocking) · `_criterion_match_: none`
Repo-wide: zero test files, no vitest/jest, no test script. Spec/ADR mandate tests for AC-005 (Critical two-tenant RLS), AC-016 (zero repeat Census), AC-009 (per-site/row geocode), AC-021 (EWKT round-trip), AC-013 (per-row report). Cross-tenant isolation ships with no automated guard.
**Disposition: ESCALATE.** Repo has never had a harness (W1 shipped none) → standing one up is a project-infra/scope decision for the operator. If convention is manual verification, downgrade to a documented manual-verification record; else land a minimal harness + the two-tenant RLS test before merge.

## CR-003 — Update path uses unverified EWKT while inserts use `place_site` RPC (inconsistent seam) — MEDIUM (question) · `_criterion_match_: none`
Inserts: `customers.ts:96-102` (RPC). Updates: `customers.ts:118-127`, `:145-153` (raw EWKT via PostgREST). ADR-002 names EWKT-insert default + RPC fallback only if round-trip fails (AC-021), verify first. Implementation inverts this and leaves move/edit/manual-recovery on the unverified EWKT update path. No AC-021 round-trip test → neither path verified, the two disagree.
**Disposition: ESCALATE.** Needs empirical round-trip confirmation (live Supabase) + seam decision (EWKT both, or RPC both). Not a blind edit.

## CR-005 — `ambiguous` failure class never produced; AC-012 pick-candidate path unreachable — LOW (suggestion) · `_criterion_match_: none`
`geocode/index.ts:93-106` always takes `matches[0]`, never returns `ambiguous`; `CustomerForm.tsx:44-48` maps ambiguous→manual anyway. Dead code; pick-candidate affordance absent.
**Disposition: DEFER** (standalone — geocode pick-candidate recovery), or amend AC-012 to record top-match-collapse as accepted.

## Nits (non-blocking)
- CR-006 index-as-key on removable SiteRowFields (`CustomerForm.tsx:160`) — APPLY (stable id).
- CR-007 geocoding the normalized address (`geocode/index.ts:214,220`) — normalize for cache key only — DISMISS/APPLY.
- CR-008 hardcoded `id="import-progress-bar"` (`CustomerImport.tsx:122`) vs `useId` convention — APPLY.
- CR-009 partial-failure orphaned state (`customers.ts:202-213`) — DEFER.

**Blocking summary:** CR-001, CR-002 mechanical. CR-004, CR-003 need operator scope/live-DB decision. Migration/RLS/Edge core sound.
