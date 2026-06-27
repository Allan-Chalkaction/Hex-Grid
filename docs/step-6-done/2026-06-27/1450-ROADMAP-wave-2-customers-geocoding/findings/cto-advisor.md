# cto-advisor

_Persisted by the orchestrator from the roadmap workflow return (FLAG-1: scripts have no FS access; agents cannot Write)._

## CTO Advisory: Wave 2 — customers-geocoding (Customers + geocoding CRUD)

**Advisor:** cto-advisor agent
**Date:** 2026-06-27
**Requested by:** roadmap Phase W (strategic/feasibility gate), operator-owned wave

### Recommendation: SIMPLIFY

**Confidence:** High

---

### One-Line Summary
Build the customer/site CRUD + geocoding wave as planned, but fold out **SQLite bulk import** (CSV only in W2) and force the **bulk-geocode execution-location** decision early — both are larger than the no-server architecture cheaply supports.

### The Proposal
Wave 2 adds a `customer` table (brand) + `site.customer_id` FK, a manual add-customer-with-sites form that geocodes each site (US Census behind a `Geocoder` interface), bulk import (CSV / SQLite), edit/move/delete, and a geocode cache for free re-adds — surfacing customers as map pins. It builds directly on the shipped W1 foundation.

### Assessment

#### Strategic Alignment: Strong
This is the wave that turns the W1 shell into a usable product: customers-as-pins is the first real user value and the data substrate every later wave (W3 exclusivity, W4 saturation) consumes. It is squarely on the build-plan's critical path, not a nice-to-have. Value compounds — the `customer`/`site` model and geocode cache are foundational.

#### Technical Feasibility: Moderate
The W1 substrate supports the core cleanly: `site` already carries `geog`/`address`/`exclusivity_radius_mi` (nullable), `geocode_cache` exists tenant-shared with RLS allowing authenticated insert, and `site` write policies are already authored. Adding `customer` + `site.customer_id` is a straightforward 0002 migration following the established per-table RLS pattern. Two items push complexity up: (1) the architecture is API-first via PostgREST with **no custom server** (ADR-001), so bulk geocoding hundreds of CSV rows against the external Census API from the browser is fragile (CORS, rate limits, batch endpoint) and likely wants a Supabase Edge Function — new infrastructure; (2) parsing an uploaded **SQLite file** client-side requires WASM (sql.js) or that same server seam.

#### Technical Debt Impact: Neutral-to-Reduces
Greenfield, near-zero existing debt (no TODO/FIXME in the 9-file source tree). Done right, this wave reduces latent debt by exercising the `site` write policies authored-but-unused in W1 and resolving the customer/site model the skeleton notes W1 conflated. Risk of *adding* debt is concentrated in the bulk-import path if it is rushed client-side.

#### Effort Estimate: Large (1-2 weeks)
Manual add + geocode + pin + edit/move/delete + the 0002 migration is Medium. CSV bulk import (parse → batch geocode → dedup → persist → errors report) plus an Edge Function for server-side geocoding pushes it to Large. SQLite import on top is what tips it past a comfortable single wave — hence the fold.

#### Risk Level: Medium
External dependency (Census geocoder availability/rate limits), file-upload attack surface, and batch-write correctness (dedup/upsert by name within tenant). All are the gates the wave already names (security-auditor, db-migration-reviewer). No critical architectural risk the existing ADR-001 cannot frame.

---

### Key Factors

**In favor:**
- Critical-path wave; unlocks the first real user value and every downstream wave's data.
- Substrate is ready — schema fields, geocode cache, and `site` write RLS already shipped in W1; this is mostly additive.

**Against:**
- "CSV / SQLite bulk import" exceeds the build-plan (CSV-only) and, with no server, SQLite parsing needs WASM — disproportionate lift for one wave.
- Bulk geocoding has no obvious home in a PostgREST-only architecture; doing it client-side is fragile and exposes batch external calls.

**Dependencies or prerequisites:**
- W1 merged to main (satisfied).
- Decide at design: `site.customer_id` nullable vs required — note that `site` is **empty** (no W1 write path), so there is **no backfill**; it can be `NOT NULL` from the start, simplifying the migration.
- Decide geocode execution location (client fetch vs Edge Function) before the bulk path is built.

---

### Alternatives Considered

| Alternative | Effort | Impact | Why ruled in/out |
|-------------|--------|--------|-----------------|
| Do nothing | None | None | Status quo is an empty shell with no way to add data — unacceptable; this is the value-delivering wave. |
| Full skeleton as-written (CSV + SQLite + bulk geocode) | XL | High | Ruled out as the wave scope: SQLite-in-browser + a bulk-geocode server seam in one wave risks a rushed file-upload/import path — the exact place debt and security holes appear. |
| **SIMPLIFY: customer/site CRUD + manual geocode + CSV import; defer SQLite; decide Edge-Function geocoding at design (chosen)** | Large | High | Delivers 100% of the user-facing value (add/import/see/edit) at meaningfully lower risk; SQLite import is the only deferred capability and is a clean standalone follow-up. |
| Manual CRUD only, no bulk import at all | Medium | Medium-High | Too aggressive a cut — CSV import is a named build-plan deliverable and a real workflow need; keep it, drop only SQLite. |

---

### ADR alignment

ADR-001 (W1 foundation) is the cited precedent. The skeleton aligns: it adopts the same per-table RLS pattern keyed off `auth_tenant_ids()` for the new `customer` table, keeps `geocode_cache` tenant-shared (no `tenant_id`), follows the `000N_*.sql` raw-migration naming (0002), and respects the API-first/no-raw-SQL-from-client decision. No path, naming, or pattern drift. One architectural decision point ADR-001 does not yet cover: **where external bulk-geocode calls execute** — if an Edge Function is introduced, it extends ADR-001's "no custom server" posture and should get an ADR addendum at architect-review (decision, not drift).

| ADR | Cited as | Drift type | Severity | Notes |
|---|---|---|---|---|
| ADR-001-multi-tenant-foundation | W1 substrate the wave builds on | none (geocode-execution is a new decision, not drift) | none / non-blocking | RLS pattern, geocode_cache shape, migration naming all aligned; flag the Edge-Function geocoding decision for architect-review as an addendum, not a conflict. |

---

### If SIMPLIFY: Pipeline Entry Notes

- **Suggested scope for pm-spec (phase 1 = this wave):** `customer` table + `site.customer_id` (recommend `NOT NULL`, no backfill needed — `site` is empty); manual add-customer-with-sites form; per-site geocode via `Geocoder` interface; pin rendering; edit/move/delete; CSV bulk import (parse → batch geocode → dedup/upsert-by-name-within-tenant → persist → errors report); geocode-cache reuse. **Defer:** SQLite import → standalone follow-up.
- **Architectural concerns for architect-review:** (1) geocode execution location — client fetch vs Supabase Edge Function; the bulk path likely requires the latter (new infra; ADR-001 addendum). (2) Confirm `site.customer_id` cardinality and that the W2 schema does not foreclose W3's customer-vs-site exclusivity-radius decision (the field currently lives on `site`).
- **Security considerations:** prime security-auditor for the file-upload (CSV) surface and the external Census calls — input validation, size/row limits, and not trusting client-supplied lat/lng on import.
- **Suggested priority:** Highest in queue — it is the next dependency for W3/W4. SQLite-import follow-up: low.
- **UI:** has_ui = true (add-customer form, CSV import + results/errors report, edit/move/delete, pins) → ui-spec dispatch required.
