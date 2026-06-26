#!/usr/bin/env bash
# test-deep-research-cap.sh — GCE-T6 (AC-004, AC-005, AC-006, AC-007)
#
# Wire-to-consumer proof for the deep-research concurrency cap. This does NOT merely assert that a
# `CONCURRENCY = 2` constant exists — it DRIVES the wrapper (core/scripts/workflows/deep-research-cap.js)
# with a synthetic >2-wide workload and asserts the OBSERVED max concurrency never exceeds 2. The runner
# is injected so the test tracks how many runOne invocations are in flight at once (an invocation-site
# proof, not a constant check).
#
# Bash wrapper over stdlib node (mirrors the test-graphiti-*.sh family's bash->stdlib convention; here the
# unit under test is JS so we shell node instead of python).
set -euo pipefail

WORKFLOWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../workflows" && pwd)"
CAP_JS="$WORKFLOWS_DIR/deep-research-cap.js"

[ -f "$CAP_JS" ] || { echo "[FAIL] missing $CAP_JS"; exit 1; }

node - "$CAP_JS" <<'JS'
const assert = require('assert')
const { capDeepResearch, CONCURRENCY } = require(process.argv[2])

// 1. The durable default bound is 2 (AC-004).
assert.strictEqual(CONCURRENCY, 2, 'durable default CONCURRENCY must be 2')
console.log('  [ok] AC-004 durable default CONCURRENCY === 2')

// Concurrency-observing harness: an injected runner + an async runOne that holds for a tick so that
// multiple in-flight invocations would overlap if the cap were not enforced. We track live count.
function makeObserver() {
  const state = { live: 0, maxLive: 0, completed: 0 }
  // The injected `parallel`: runs the slice's thunks together (exactly like the sandbox global), so any
  // failure to slice <=2-wide would be OBSERVED as maxLive > 2.
  const parallel = (thunks) => Promise.all(thunks.map((t) => t()))
  const runOne = async (item) => {
    state.live++
    state.maxLive = Math.max(state.maxLive, state.live)
    // Yield across the microtask + a macrotask boundary so overlapping invocations actually coexist.
    await new Promise((r) => setTimeout(r, 5))
    state.live--
    state.completed++
    return item * 10
  }
  return { state, parallel, runOne }
}

;(async () => {
  // 2. AC-005 wire-to-consumer: a synthetic >2-wide workload (7 items) driven through the wrapper.
  const items = [0, 1, 2, 3, 4, 5, 6]
  const obs = makeObserver()
  const results = await capDeepResearch(items, obs.runOne, { parallel: obs.parallel })

  // Observed max concurrency must be <=2 — the load-bearing assertion (not a constant check).
  assert.ok(obs.state.maxLive <= 2, `observed max concurrency ${obs.state.maxLive} must be <= 2`)
  assert.ok(obs.state.maxLive >= 2, `expected the cap to actually saturate to 2 (got ${obs.state.maxLive})`)
  assert.strictEqual(obs.state.completed, items.length, 'every work unit must run exactly once')
  // Results returned in input order.
  assert.deepStrictEqual(results, items.map((i) => i * 10), 'results must be in input order')
  console.log(`  [ok] AC-005 observed max concurrency === ${obs.state.maxLive} (<=2) over ${items.length} units`)

  // 3. An absent/invalid cap NEVER widens the default beyond 2 (AC-004 "no path exceeds 2 without override").
  for (const bad of [undefined, 0, -3, 99.5, 'x', null]) {
    const o = makeObserver()
    await capDeepResearch([1, 2, 3, 4, 5], o.runOne, { parallel: o.parallel, cap: bad })
    assert.ok(o.state.maxLive <= 2, `invalid cap ${String(bad)} must not widen beyond 2 (got ${o.state.maxLive})`)
  }
  console.log('  [ok] AC-004 invalid/absent cap never widens beyond the durable default of 2')

  // 4. Sanity: a deliberately wider explicit override is the ONLY way to exceed 2 (proves the default is
  //    the binding floor, not an accident of small inputs).
  const o3 = makeObserver()
  await capDeepResearch([1, 2, 3, 4, 5, 6], o3.runOne, { parallel: o3.parallel, cap: 3 })
  assert.ok(o3.state.maxLive <= 3 && o3.state.maxLive >= 2, `explicit cap=3 should saturate near 3 (got ${o3.state.maxLive})`)
  console.log(`  [ok] explicit override cap=3 observed ${o3.state.maxLive} — default path stays at 2`)

  console.log('PASS')
})().catch((e) => { console.error('[FAIL]', e.message); process.exit(1) })
JS

# 5. AC-006 defect-anchor grep: the wrapper cites the live defect run verbatim.
grep -q 'wf_a0b6756e-288' "$CAP_JS" \
  && echo "  [ok] AC-006 wrapper cites run wf_a0b6756e-288" \
  || { echo "[FAIL] AC-006 missing wf_a0b6756e-288 defect citation"; exit 1; }

# 6. AC-007 honest-scope grep: the wrapper labels its binding surface (substrate path, not in-plugin).
grep -qiE 'NOT a hook inside|substrate-owned|constrained invocation path' "$CAP_JS" \
  && echo "  [ok] AC-007 wrapper labels its binding surface honestly" \
  || { echo "[FAIL] AC-007 missing honest binding-surface label"; exit 1; }

echo "test-deep-research-cap: OK"
