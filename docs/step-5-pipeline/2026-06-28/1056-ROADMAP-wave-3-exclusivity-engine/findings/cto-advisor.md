# CTO Advisory — Wave 3 (exclusivity-engine)

**Recommendation: GO (conditioned — SIMPLIFY the build scope).** Confidence: High.

Build the exclusivity engine next — it's the product's core value and the schema was pre-provisioned for it (W1 reserved `site.geog` geography + GIST index + `site.exclusivity_radius_mi`). W4 (area-saturation) is blocked until it ships.

## SIMPLIFY (fold into spec)
- **Defer H3 hex-fill rendering to Wave 4** — it's W4's signature payload (area-saturation); bundling it imports the H3 dep + per-viewport compute a wave early. W3 = **circles-only** zones (deck.gl ScatterplotLayer, `radiusUnits:'meters'`).
- **Warn-default** add/move disposition (not block) for the first cut. If "block" must be authoritative it requires server-side enforcement in place_site/update to avoid TOCTOU; scope first cut to warn.

## Feasibility: straightforward
`ST_DWithin(geography, geography, meters)` is GIST-accelerated, geodesic, textbook. Miles→meters = ×1609.344. Add/move write paths exist (place_site, updateSiteLocation). Zone layers extend sitePinsLayer/MapShell reactive-overlay pattern. RLS scopes conflict detection to tenant by construction.

## Risks / pipeline notes
- **Keep conflict query server-side** (RPC/view leveraging GIST+RLS); client renders, does not compute haversine (else TOCTOU + duplicated math).
- Resolve vertical placement (customer jsonb vs reserved site.vertical) at plan time → architect.
- New conflict RPC must be `security invoker` + pinned search_path (mirror place_site) — prevent cross-tenant conflict leakage; security-auditor confirms on the migration.
- Perf: single add/move check = one GIST query (negligible); all-zones self-join GIST-accelerated, fine to ~10k sites/tenant.
- Effort: Large (~1–2 wks build) with hex-fill deferred.

## ADR alignment
ADR-001/002 aligned; one non-blocking naming drift (vertical placement) for architect to resolve. No escalation.
