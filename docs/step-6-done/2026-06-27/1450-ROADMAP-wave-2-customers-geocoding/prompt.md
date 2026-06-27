# Roadmap Phase W — Wave 2 (customers-geocoding)

**Ticket key:** HGW-2

**Mode:** autonomous (ADR-054 default; no `--attended`).

**Task:** Graduate the Wave 2 fat skeleton (`customers-geocoding`) of the **hex-grid** epic into a
buildable wave spec + per-ticket prompts that `/orchestrated customers-geocoding` can consume.

Run the Phase-W funnel (cto-advisor → architect-review → ui-spec → pm-spec → spec-decomposer →
graph-validate → pm-spec render → planner self-QA → finalize) over `round-0-intent.md`.

**Binding context:** the operator's domain-model clarification in `round-0-intent.md` — `customer`
(brand) and `site` (location) are distinct, 1→N. Wave 2 adds a `customer` table + `site.customer_id`
(a `0002` migration). Geocoding runs **per site**, not per customer. The funnel must resolve the open
questions listed in the intent.

**Note:** no canonical `docs/step-3-specs/hex-grid/roadmap.md` exists; the per-wave skeletons +
`build-plan.md` are the de-facto roadmap. This run graduates Wave 2 only.

**Epic slug:** hex-grid · **Wave slug:** customers-geocoding · **N:** 2
