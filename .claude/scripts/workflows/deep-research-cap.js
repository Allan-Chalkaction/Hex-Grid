// deep-research-cap.js — substrate-owned deep-research concurrency cap (GCE-T6, ADR-097)
//
// WHY (the live correctness defect this fixes):
//   Run wf_a0b6756e-288 fanned out 100 deep-research agents -> hit the server-side throttle ->
//   returned 0 confirms / 0 refutes, which the verify leg reads as FALSE-NEGATIVE REFUTES. That is a
//   CORRECTNESS defect (real claim votes destroyed), not merely a cost concern. Capping deep-research
//   fan-out to <=2 concurrent as a DURABLE DEFAULT stops the throttle from corrupting verify results.
//   Latency regression is acceptable against returning real claim votes.
//
// SCOPE / BINDING SURFACE (honest — AC-007, per GCE-T5 findings/deep-research-target.md):
//   Deep-research is owned by an EXTERNAL MCP plugin (`exa`, exa-mcp-server). ADR-097 D3 forbids editing
//   plugin internals, and the plugin source is not even vendored/installed in this environment. This
//   wrapper is therefore NOT a hook inside the exa plugin. It is the substrate-owned CONSTRAINED
//   INVOCATION PATH: a caller routes its deep-research work through `capDeepResearch(...)` INSTEAD OF a
//   raw plugin fan-out. The cap binds every caller that uses this wrapper — it cannot constrain a raw
//   direct call that bypasses it. GCE-T5's verdict: WRAPPABLE (real enforcement at the substrate-owned
//   path), not uninterceptable-advisory-only. This header states that scope plainly so no consumer
//   mistakes the wrapper for an in-plugin enforcement point.
//
// DURABLE DEFAULT (AC-004): CONCURRENCY is a hard bound of 2 baked in as the default. It is NOT a
//   per-session `--concurrency` flag the operator must remember. An explicit override exists for tests/
//   tooling, but there is no code path where the *default* exceeds 2.
//
// IDIOM (ADR-039): mirrors the CONCURRENCY-bounded `await parallel(slice)` slicing in
//   core/scripts/workflows/orchestrated.js (:476/:567/:781) and nimble.js (:122/:239). In the Workflow
//   sandbox `parallel` is an injected global; to keep this wrapper TESTABLE off-sandbox (AC-005, the
//   wire-to-consumer proof) the concurrent runner is injected as a parameter, defaulting to the sandbox
//   `parallel` global when present.

'use strict'

// The durable default cap. Deep-research fan-out admits at most this many concurrent agents.
const CONCURRENCY = 2

// Resolve the concurrent runner: prefer an explicitly injected one (tests/tooling), else the
// Workflow-sandbox `parallel` global, else a minimal stdlib Promise.all fallback. `parallel(thunks)`
// takes an array of zero-arg thunks and resolves to the array of their results, exactly like the
// engine scripts' usage.
function resolveRunner(injected) {
  if (typeof injected === 'function') return injected
  if (typeof globalThis !== 'undefined' && typeof globalThis.parallel === 'function') {
    return globalThis.parallel
  }
  return (thunks) => Promise.all(thunks.map((t) => t()))
}

/**
 * Run `runOne` over every item in `items`, never exceeding `cap` (default CONCURRENCY=2) concurrent
 * invocations. Work is sliced into <=cap-wide batches; each batch is awaited before the next begins,
 * so observed max concurrency never exceeds `cap`. Results are returned in input order.
 *
 * This is the constrained deep-research invocation path: a caller invokes capDeepResearch(items, runOne)
 * INSTEAD OF a raw >cap-wide plugin fan-out. The cap is READ and ENFORCED here on every invocation —
 * it is not a dead `const CAP=2` (AC-005).
 *
 * @param {Array}    items   work units (e.g. per-claim deep-research requests).
 * @param {Function} runOne  async (item, index) => result for a single unit (the per-agent plugin call).
 * @param {Object}   [opts]
 * @param {number}   [opts.cap]      override the durable default (tests/tooling only; default stays 2).
 * @param {Function} [opts.parallel] inject the concurrent runner (tests); defaults to sandbox `parallel`.
 * @returns {Promise<Array>} results in input order.
 */
async function capDeepResearch(items, runOne, opts = {}) {
  if (!Array.isArray(items)) throw new TypeError('capDeepResearch: items must be an array')
  if (typeof runOne !== 'function') throw new TypeError('capDeepResearch: runOne must be a function')

  // Hard floor at 1; the DEFAULT is always CONCURRENCY (2) — an absent/invalid cap never widens it.
  const cap = Number.isInteger(opts.cap) && opts.cap >= 1 ? opts.cap : CONCURRENCY
  const run = resolveRunner(opts.parallel)

  const results = new Array(items.length)
  for (let start = 0; start < items.length; start += cap) {
    const slice = items.slice(start, start + cap)
    // <=cap thunks awaited together; the next slice does not begin until this one settles.
    const sliceResults = await run(slice.map((item, j) => () => runOne(item, start + j)))
    for (let j = 0; j < sliceResults.length; j++) results[start + j] = sliceResults[j]
  }
  return results
}

module.exports = { capDeepResearch, CONCURRENCY }
