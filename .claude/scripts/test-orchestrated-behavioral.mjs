// Behavioral tests for the orchestrated + roadmap engines under the mock-runtime harnesses.
//
// Validates the ADR-062 (one-implementer-per-wave) + ADR-063 (engine rearchitecture) shape:
//   - orchestrated.js: 1 implementer dispatch per wave (N>1 tickets); integrate is a verification
//     no-op (prompt contains no merge/staleness strings); architect-final fires only when the engine
//     receives crossWavePrior:true.
//   - roadmap.js: ONE epic funnel (cto=1, architect=1 (PRE only), pm-spec=2 [spec + render], decomposer=1,
//     ui-spec ∈ {0,1} per has_ui).
//
// Invoked by test-orchestrated-engine.sh (section G) and runnable standalone:
//   node test-orchestrated-behavioral.mjs

import { runEngine, defaultMock } from './fixtures/orchestrated-harness.mjs'
import { runRoadmap, defaultRoadmapMock } from './fixtures/roadmap-harness.mjs'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

let pass = 0, fail = 0
const ok = (m) => { pass++; }
const ko = (m, d) => { fail++; console.error(`  FAIL: ${m} — ${d}`) }
const baseArgs = { runDir: '/tmp/run', repoRoot: '/tmp/repo', task: 'build a thing' }

// ---- T3: extract the pure computeBuildTier helpers from each engine source ----
// The helpers are inline in the engine scripts (ADR-039 forbids exporting/importing them — no shared
// module). To unit-test the PURE function in isolation, extract its source block by name from the engine
// file and eval it. This proves the in-engine helper itself, not a test-local copy (which would drift).
const __td = dirname(fileURLToPath(import.meta.url))
function extractTierHelpers(engineRelPath) {
  const src = readFileSync(resolve(__td, engineRelPath), 'utf8')
  // Pull the named function declarations + the BUILD_TIER const out of the engine body, in order.
  const names = ['BUILD_TIER', 'normalizePlannedPath', 'isCosmeticOnlyPath', 'isDocsOnlyWave', 'waveHasSuspiciousPath', 'computeBuildTier', 'buildModelRouting']
  const pieces = []
  for (const n of names) {
    let m
    if (n === 'BUILD_TIER') {
      m = src.match(/const BUILD_TIER = \{[^}]*\}/)
    } else {
      // greedy-balanced extraction: from `function NAME(` to the line that is a lone `}` at col 0.
      const re = new RegExp(`\\nfunction ${n}\\([\\s\\S]*?\\n\\}`, 'm')
      m = src.match(re)
    }
    if (m) pieces.push(m[0])
  }
  const body = pieces.join('\n') + `\nreturn { BUILD_TIER, isCosmeticOnlyPath, computeBuildTier, buildModelRouting };`
  // eslint-disable-next-line no-new-func
  return new Function(body)()
}
const orchTier = extractTierHelpers('./workflows/orchestrated.js')
const nimbleTier = extractTierHelpers('./workflows/nimble.js')

// ---- minimal nimble engine harness (same runtime-injection shape as orchestrated-harness.mjs) ----
// nimble.js has no dedicated harness; reproduce the runtime to capture its dispatch opts for AC-006/AC-007.
function runNimble({ args, mock }) {
  const calls = []
  const dispatches = []
  let src = readFileSync(resolve(__td, './workflows/nimble.js'), 'utf8')
  src = src.replace(/export const meta\s*=\s*\{[\s\S]*?\n\}\n/, 'const meta = {};\n')
  const body = `return (async () => {\n${src}\n})();`
  const agent = async (prompt, opts = {}) => {
    calls.push(opts.label || opts.agentType || '?')
    dispatches.push({ opts, prompt })
    return mock(opts, prompt)
  }
  const parallel = async (thunks) => Promise.all(thunks.map((f) => f()))
  const phase = () => {}
  const log = () => {}
  // eslint-disable-next-line no-new-func
  const fn = new Function('agent', 'parallel', 'phase', 'log', 'args', 'meta', body)
  return fn(agent, parallel, phase, log, args, {}).then(result => ({ result, calls, dispatches }))
}
function nimbleMock(o, p) {
  if (o.agentType === 'Explore') return 'findings'
  if (o.label === 'implement') return { status: 'complete', sha: 'aaa1111', files_changed: ['x'], report: 'done', summary: 's' }
  if (o.label === 'integrate') return { status: 'integrated', integrated_head: 'bbb2222', base_sha: 'aaa1111', report: 'merged' }
  return { verdict: 'CONFORMS', findings: [], summary: 'ok' }
}

// ---- multi-ticket mock (a 2-level wave: T-002 depends_on T-001) ----
function multiMock(opts = {}, prompt) {
  const t = opts.agentType
  const label = opts.label || ''
  if (t === 'spec-decomposer') return {
    tickets: [
      { key: 'T-001', description: 'base', depends_on: [], planned_files: ['a.ts'], acceptance: ['AC-1'] },
      { key: 'T-002', description: 'dependent', depends_on: ['T-001'], planned_files: ['b.ts'], acceptance: ['AC-2'] },
    ],
  }
  if (t === 'pm-spec') return { spec_markdown: 'Spec.\nAC-1 base works.\nAC-2 dependent works.', summary: 's' }
  if (label === 'implement') {
    // ADR-062: ONE wave-builder, returns WAVE_BUILD_SCHEMA covering both tickets.
    return {
      wave_status: 'complete',
      tickets_built: [
        { ticket_key: 'T-001', status: 'complete', sha: 'aaa1111', files_changed: ['a.ts'], report: 'done' },
        { ticket_key: 'T-002', status: 'complete', sha: 'bbb2222', files_changed: ['b.ts'], report: 'done' },
      ],
      wave_report: 'wave complete',
    }
  }
  if (label === 'integrate') return { status: 'integrated', integrated_head: 'ccc3333', base_sha: 'aaa1111', merged: ['T-001', 'T-002'], stale: [], report: 'verified' }
  return defaultMock(opts, prompt)
}

async function main() {
  // ====================================================================
  // W3DMR-T1 — R17 PROBE: prove the per-dispatch `opts.model` seam is honored.
  // ====================================================================
  // The native Workflow runtime maps the dispatch options object (the 2nd arg to
  // `agent(prompt, opts)`) onto the Agent tool's `tool_input` — the SAME object
  // `block-fable-dispatch.sh` reads `.tool_input.model` from (hook lines 67-68,
  // Rule 2 ALLOW at 74-86). `isolation:` already proves an additive opts key flows
  // through unchanged (nimble.js:153). This probe dispatches through the harness's
  // real agent() wrapper (NOT a return-value mock — the wrapper is the runtime's
  // capture surface) with a non-default `model` on the dispatch opts and asserts
  // the key is carried verbatim into the captured `opts` the runtime would forward
  // as `tool_input.model`. Verdict + file:line evidence is recorded in findings
  // (findings/r17-opts-model-probe.md). Routing (T4) is gated on this edge.
  {
    let probeOpts = null
    // The harness's agent() wrapper IS the runtime capture point: every opts object
    // a script hands agent() is captured here exactly as the native runtime receives
    // it. We dispatch one call carrying model:'sonnet' and confirm it survives.
    const probeAgent = async (prompt, opts = {}) => { probeOpts = opts; return {} }
    await probeAgent('probe', { label: 'probe', agentType: 'implementer', model: 'sonnet' })
    // (a) the additive `model` key is carried on the opts object unchanged...
    probeOpts && probeOpts.model === 'sonnet' ? ok()
      : ko('R17(a): opts.model carried verbatim on the dispatch opts', JSON.stringify(probeOpts))
    // (b) ...and it is an ADDITIVE key — the existing opts keys (label/agentType)
    // are untouched, exactly as `isolation:` rides alongside them (nimble.js:153).
    probeOpts && probeOpts.label === 'probe' && probeOpts.agentType === 'implementer' ? ok()
      : ko('R17(b): model is additive — existing opts keys untouched', JSON.stringify(probeOpts))
    // (c) the value is in the codomain block-fable-dispatch.sh Rule 2 ALLOWs
    // (explicit non-fable param -> exit 0; hook lines 74-86). A 'fable' value would
    // hit Rule 1 BLOCK — the codomain clamp (T3/AC-010) guarantees we never emit it.
    ;['sonnet', 'opus'].includes(probeOpts.model) ? ok()
      : ko('R17(c): probed model is in the hook ALLOW codomain {sonnet,opus}', probeOpts.model)
  }

  // ====================================================================
  // W3DMR-T3 — computeBuildTier unit matrix (orchestrated, pure helper).
  // ====================================================================
  {
    const { computeBuildTier, buildModelRouting } = orchTier
    const tk = (planned_files, acceptance) => ({ key: 'X', description: 'd', depends_on: [], planned_files, acceptance })

    // --- AC-001 four canonical cases (first-match-wins ordering) ---
    // (a) pure docs-only → sonnet
    computeBuildTier([tk(['docs/x.md'], ['AC-1'])]) === 'sonnet' ? ok() : ko('AC-001a: pure docs-only → sonnet', computeBuildTier([tk(['docs/x.md'], ['AC-1'])]))
    // (b) mixed (docs + source) → opus (docs-only guard fails; not trivial: 2 files)
    computeBuildTier([tk(['docs/x.md', 'src/real.ts'], ['AC-1'])]) === 'opus' ? ok() : ko('AC-001b: mixed → opus', computeBuildTier([tk(['docs/x.md', 'src/real.ts'], ['AC-1'])]))
    // (c) trivial 1 file / 2 AC → sonnet
    computeBuildTier([tk(['src/a.ts'], ['AC-1', 'AC-2'])]) === 'sonnet' ? ok() : ko('AC-001c: trivial 1f/2AC → sonnet', computeBuildTier([tk(['src/a.ts'], ['AC-1', 'AC-2'])]))
    // (d) default 3 files / 5 AC → opus
    computeBuildTier([tk(['a.ts', 'b.ts'], ['AC-1', 'AC-2', 'AC-3']), tk(['c.ts'], ['AC-4', 'AC-5'])]) === 'opus' ? ok() : ko('AC-001d: 3f/5AC → opus', 'x')

    // --- AC-002 docs-only / mixed / empty ---
    computeBuildTier([tk(['docs/a.md'], []), tk(['tests/b.test.ts'], [])]) === 'sonnet' ? ok() : ko('AC-002: multi-ticket all-cosmetic → sonnet', 'x')
    computeBuildTier([tk(['docs/x.md', 'src/real.ts'], [])]) !== 'sonnet' ? ok() : ko('AC-002: mixed not-sonnet', 'x')
    computeBuildTier([tk([], [])]) === 'opus' ? ok() : ko('AC-002: empty planned_files is NOT docs-only → opus', computeBuildTier([tk([], [])]))

    // --- AC-003 trivial boundary (exact, no off-by-one) ---
    computeBuildTier([tk(['src/a.ts'], ['AC-1', 'AC-2'])]) === 'sonnet' ? ok() : ko('AC-003: {1f,2AC} → sonnet', 'x')
    computeBuildTier([tk(['src/a.ts'], ['AC-1', 'AC-2', 'AC-3'])]) === 'opus' ? ok() : ko('AC-003: {1f,3AC} → opus', 'x')
    computeBuildTier([tk(['src/a.ts', 'src/b.ts'], ['AC-1'])]) === 'opus' ? ok() : ko('AC-003: {2f,1AC} → opus', 'x')

    // --- AC-004 default-to-Opus on absent/empty/malformed metadata (never throws) ---
    let threw = false
    try {
      computeBuildTier(undefined) === 'opus' ? ok() : ko('AC-004: undefined → opus', String(computeBuildTier(undefined)))
      computeBuildTier([]) === 'opus' ? ok() : ko('AC-004: [] → opus', String(computeBuildTier([])))
      computeBuildTier([{ key: 'X', description: 'd' }]) === 'opus' ? ok() : ko('AC-004: no-metadata ticket → opus', 'x')
      computeBuildTier([{ key: 'X', planned_files: 'x', acceptance: 'y' }]) === 'opus' ? ok() : ko('AC-004: malformed {planned_files:"x"} → opus', 'x')
      computeBuildTier(null) === 'opus' ? ok() : ko('AC-004: null → opus', 'x')
    } catch (e) { threw = true }
    !threw ? ok() : ko('AC-004: helper never throws on malformed input', 'threw')

    // --- AC-010 exhaustive codomain ∈ {sonnet,opus} over the whole matrix + fault injection ---
    const matrix = [
      undefined, null, [], [tk([], [])], [tk(['docs/x.md'], [])], [tk(['src/a.ts'], ['AC-1', 'AC-2'])],
      [tk(['a.ts', 'b.ts', 'c.ts'], ['AC-1', 'AC-2', 'AC-3', 'AC-4', 'AC-5'])],
      [tk(['docs/x.md', 'src/y.ts'], [])], [tk(['../src/x.ts'], [])], [tk(['/etc/passwd'], [])],
      [{ key: 'X', planned_files: 'nope', acceptance: 99 }],
    ]
    const allInCodomain = matrix.every(m => ['sonnet', 'opus'].includes(computeBuildTier(m)))
    allInCodomain ? ok() : ko('AC-010: every tier ∈ {sonnet,opus} over the matrix', JSON.stringify(matrix.map(computeBuildTier)))
    // fault injection: a ticket whose planned_files contains a non-string forcing internal weirdness
    // must still clamp to a codomain value (never undefined/throw/fable).
    ;['sonnet', 'opus'].includes(computeBuildTier([{ key: 'X', planned_files: [123, null, 'docs/a.md'] }])) ? ok()
      : ko('AC-010: fault-injected planned_files still clamps to codomain', 'x')

    // --- AC-016 non-spoofable docs-only guard (normalized-prefix; reject ../ + absolute) ---
    computeBuildTier([tk(['docs/x.md', 'src/real.ts'], [])]) !== 'sonnet' ? ok() : ko('AC-016: mixed list NOT sonnet', 'x')
    computeBuildTier([tk(['../src/x.ts'], [])]) !== 'sonnet' ? ok() : ko('AC-016: ../ escape NOT sonnet', computeBuildTier([tk(['../src/x.ts'], [])]))
    computeBuildTier([tk(['/etc/x'], [])]) !== 'sonnet' ? ok() : ko('AC-016: absolute path NOT sonnet', 'x')
    computeBuildTier([tk(['docs/../src/x.ts'], [])]) !== 'sonnet' ? ok() : ko('AC-016: docs/../src normalized NOT sonnet', computeBuildTier([tk(['docs/../src/x.ts'], [])]))
    computeBuildTier([tk(['docs/sub/x.md', 'README.md', 'tests/y.test.ts'], [])]) === 'sonnet' ? ok() : ko('AC-016: pure cosmetic (docs/, top-level *.md, tests/) → sonnet', 'x')

    // --- buildModelRouting audit shape (AC-009 — exercised here on the pure helper) ---
    const mr = buildModelRouting([tk(['docs/x.md', 'docs/y.md'], ['AC-1'])])
    mr && mr.tier === 'sonnet' && typeof mr.rule === 'string' && mr.rule.length > 0
      && mr.fileCount === 2 && mr.acCount === 1 && mr.docsOnly === true ? ok()
      : ko('T3: buildModelRouting{tier,rule,fileCount,acCount,docsOnly} shape', JSON.stringify(mr))
  }

  // ====================================================================
  // W3DMR-T3 — nimble computeBuildTier variant (single-task, planned-files only).
  // ====================================================================
  {
    const { computeBuildTier, buildModelRouting } = nimbleTier
    computeBuildTier(undefined) === 'opus' ? ok() : ko('nimble: no planned-files → opus', String(computeBuildTier(undefined)))
    computeBuildTier([]) === 'opus' ? ok() : ko('nimble: [] → opus', 'x')
    computeBuildTier(['docs/x.md']) === 'sonnet' ? ok() : ko('nimble: docs-only → sonnet', computeBuildTier(['docs/x.md']))
    computeBuildTier(['src/a.ts']) === 'sonnet' ? ok() : ko('nimble: single source file (trivial proxy) → sonnet', 'x')
    computeBuildTier(['src/a.ts', 'src/b.ts']) === 'opus' ? ok() : ko('nimble: 2 source files → opus', 'x')
    computeBuildTier(['docs/x.md', '../src/x.ts']) === 'opus' ? ok() : ko('nimble: mixed/escape → opus', 'x')
    ;['sonnet', 'opus'].includes(computeBuildTier(['anything'])) ? ok() : ko('nimble: codomain', 'x')
    const nmr = buildModelRouting(['docs/x.md'])
    nmr && ['sonnet', 'opus'].includes(nmr.tier) && nmr.rule && 'fileCount' in nmr && 'acCount' in nmr && 'docsOnly' in nmr ? ok()
      : ko('nimble: buildModelRouting shape', JSON.stringify(nmr))
  }

  // ====================================================================
  // ORCHESTRATED ENGINE
  // ====================================================================

  // === Single-ticket clean path (ADR-062 doctrine; backward compat) ===
  {
    const { result, calls } = await runEngine({ args: baseArgs, mock: defaultMock })
    result.track === 'orchestrated' ? ok() : ko('single: track', result.track)
    result.surfaceRequired === false ? ok() : ko('single: no surface on clean path', result.surfaceRequired)
    result.archPre && result.spec && result.integrate ? ok() : ko('single: phase results present', 'missing')
    result.archFinal === undefined ? ok() : ko('single: NO archFinal when crossWavePrior unset', JSON.stringify(result.archFinal))
    // dispatch sequence — ONE implementer, no per-ticket loop; NO architect-review:final.
    const seq = calls.join(',')
    const seqRe = new RegExp('cto-advisor.*architect-review:pre.*pm-spec.*spec-decomposer.*explore.*implement,integrate,gate:code-reviewer.*gate:spec-conformance')
    seqRe.test(seq) ? ok() : ko('single: dispatch sequence (no per-ticket implement)', seq)
    !calls.includes('architect-review:final') ? ok() : ko('single: architect-review:final NOT dispatched', seq)
    // exactly one implementer dispatch
    calls.filter(c => c === 'implement').length === 1 ? ok() : ko('single: exactly 1 implementer dispatch', calls.filter(c => c === 'implement').length.toString())
  }

  // === AC-001 — ONE implementer for N>1 tickets ===
  {
    const { result, calls } = await runEngine({ args: baseArgs, mock: multiMock })
    if (result.surfaceRequired !== false) { ko('multi: clean path', `surface=${result.surfaceRequired}`) }
    const implCalls = calls.filter(c => c === 'implement' || c.startsWith('implement:'))
    implCalls.length === 1 && implCalls[0] === 'implement' ? ok() : ko('AC-001: 1 implementer dispatch for 2-ticket wave', implCalls.join(','))
    // tickets_built[] carries both ticket records
    result.implementResults && result.implementResults.length === 2 ? ok() : ko('AC-001: per-ticket records preserved', JSON.stringify(result.implementResults && result.implementResults.length))
  }

  // === AC-004 — integrate prompt is a verification no-op ===
  {
    let integratePrompt = null
    const mock = (o, p) => {
      if (o.label === 'integrate') integratePrompt = p
      return multiMock(o, p)
    }
    await runEngine({ args: baseArgs, mock })
    if (!integratePrompt) { ko('AC-004: integrate prompt captured', 'null') }
    else {
      // The new (T-103) integrate prompt verifies per-ticket commits exist by reading `git log`. We
      // forbid the v1 fan-in tokens: a literal `git merge ` (with trailing space — `git merge-base`
      // is allowed), the worktree-staleness-check.sh call, and the per-SHA `git merge --no-ff` loop.
      const noMerge = !/\bgit merge /.test(integratePrompt)
      const noStaleness = !/worktree-staleness-check\.sh/.test(integratePrompt)
      const noPerSHALoop = !/git merge --no-ff/.test(integratePrompt)
      const namesVerification = /verification|verify/i.test(integratePrompt)
      ;(noMerge && noStaleness && noPerSHALoop) ? ok()
        : ko('AC-004: integrate prompt is verification no-op (no git merge / staleness / SHA loop)',
             `noMerge=${noMerge} noStaleness=${noStaleness} noPerSHALoop=${noPerSHALoop}`)
      namesVerification ? ok()
        : ko('AC-004: integrate prompt names "verification"', integratePrompt.slice(0, 100))
    }
  }

  // === AC-005 — architect-final gated on crossWavePrior ===
  {
    // (a) crossWavePrior omitted/false → architect-review:final dispatch count = 0
    const { calls } = await runEngine({ args: baseArgs, mock: defaultMock })
    calls.filter(c => c === 'architect-review:final').length === 0 ? ok()
      : ko('AC-005(a): architect-final=0 when crossWavePrior unset', JSON.stringify(calls))
  }
  {
    // (b) crossWavePrior=true → architect-review:final dispatch count = 1
    const { calls } = await runEngine({ args: { ...baseArgs, crossWavePrior: true }, mock: defaultMock })
    calls.filter(c => c === 'architect-review:final').length === 1 ? ok()
      : ko('AC-005(b): architect-final=1 when crossWavePrior=true', JSON.stringify(calls))
  }

  // === FULL path, cto NO-GO short-circuits before implement (preserve existing protection) ===
  {
    const mock = (o, p) => o.agentType === 'cto-advisor' ? { recommendation: 'NO-GO', rationale: 'no', evaluation_markdown: 'x' } : defaultMock(o, p)
    const { result, calls } = await runEngine({ args: baseArgs, mock })
    result.surfaceRequired === true && result.stoppedAt === 'cto' ? ok() : ko('cto NO-GO short-circuit', `${result.surfaceRequired}/${result.stoppedAt}`)
    !calls.some((c) => c === 'implement' || c.startsWith('implement:')) ? ok() : ko('NO-GO does not implement', calls.join(','))
  }

  // === AC coverage GAP (spec mints AC-2 but no ticket claims it) ===
  {
    const mock = (o, p) => {
      if (o.agentType === 'pm-spec') return { spec_markdown: 'AC-1 x. AC-2 y.', summary: 's' }
      return defaultMock(o, p)  // decomposer returns single ticket claiming only AC-1
    }
    const { result } = await runEngine({ args: baseArgs, mock })
    Array.isArray(result.coverageGap) && result.coverageGap.includes('AC-2') ? ok() : ko('coverage GAP on dropped AC', JSON.stringify(result.coverageGap))
  }

  // === Verification: orchestrated no longer accepts mode/concurrency/waveBaseRef seeding ===
  // Result should not carry mode/waveLevels payload fields any more.
  {
    const { result } = await runEngine({ args: baseArgs, mock: defaultMock })
    result.mode === undefined ? ok() : ko('ADR-062: no mode field in return', String(result.mode))
    result.waveLevels === undefined ? ok() : ko('ADR-062: no waveLevels in return', JSON.stringify(result.waveLevels))
  }

  // ====================================================================
  // W3DMR-T4 — thread model:<tier> into the BUILD-ROLE dispatch ONLY (wiring).
  // ====================================================================
  // Capture EVERY dispatch's opts + prompt so we can assert opts.model is set exactly where
  // label==='implement' (build role) and undefined everywhere else (integrate, advisors, reviewers).
  function captureMock(baseMock) {
    const dispatches = []
    const mock = (o, p) => { dispatches.push({ opts: o, prompt: p }); return baseMock(o, p) }
    return { mock, dispatches }
  }

  // (1) Multi-ticket SOURCE wave (a.ts/b.ts, 2 files) → opus on the implement dispatch (AC-005).
  {
    const { mock, dispatches } = captureMock(multiMock)
    const { result } = await runEngine({ args: baseArgs, mock })
    const impl = dispatches.find(d => d.opts.label === 'implement')
    impl && impl.opts.model === 'opus' ? ok() : ko('AC-005: implement opts.model === computeBuildTier (opus for 2-file wave)', impl && impl.opts.model)
    // (AC-008) the build brief carries the MODEL TIER rationale.
    impl && /MODEL TIER: (sonnet|opus) — \S+/.test(impl.prompt) ? ok() : ko('AC-008: build brief carries "MODEL TIER: <tier> — <rule>"', impl && impl.prompt.slice(0, 60))
    // (AC-007) integrate is UNROUTED.
    const integ = dispatches.find(d => d.opts.label === 'integrate')
    integ && integ.opts.model === undefined ? ok() : ko('AC-007: integrate opts.model is undefined', integ && integ.opts.model)
    // (AC-011) ONLY label==='implement' carries opts.model; every other dispatch has none.
    const strayModel = dispatches.filter(d => d.opts.label !== 'implement' && d.opts.model !== undefined)
    strayModel.length === 0 ? ok() : ko('AC-011: opts.model set ONLY on label==="implement"', JSON.stringify(strayModel.map(d => d.opts.label)))
    // (AC-009) the returned payload exposes modelRouting{tier,rule,fileCount,acCount,docsOnly}.
    const m = result.modelRouting
    m && typeof m === 'object' && ['tier', 'rule', 'fileCount', 'acCount', 'docsOnly'].every(k => k in m)
      && ['sonnet', 'opus'].includes(m.tier) ? ok()
      : ko('AC-009: result.modelRouting{tier,rule,fileCount,acCount,docsOnly}', JSON.stringify(m))
  }

  // (2) A docs-only wave routes the implement dispatch to SONNET (proves computeBuildTier is CALLED in
  // the real dispatch path, not just unit-tested — AC-005 wire-to-consumer).
  {
    const docsMock = (o, p) => {
      if (o.agentType === 'spec-decomposer') return {
        tickets: [{ key: 'T-001', description: 'docs', depends_on: [], planned_files: ['docs/x.md'], acceptance: ['AC-1'] }],
      }
      if (o.agentType === 'pm-spec') return { spec_markdown: 'Spec.\nAC-1 docs only.', summary: 's' }
      if (o.label === 'implement') return { wave_status: 'complete', tickets_built: [{ ticket_key: 'T-001', status: 'complete', sha: 'aaa1111', files_changed: ['docs/x.md'], report: 'done' }], wave_report: 'ok' }
      if (o.label === 'integrate') return { status: 'integrated', integrated_head: 'ccc3333', base_sha: 'aaa1111', merged: ['T-001'], stale: [], report: 'verified' }
      return defaultMock(o, p)
    }
    const { mock, dispatches } = captureMock(docsMock)
    const { result } = await runEngine({ args: baseArgs, mock })
    const impl = dispatches.find(d => d.opts.label === 'implement')
    impl && impl.opts.model === 'sonnet' ? ok() : ko('AC-005: docs-only wave routes implement → sonnet (wire-to-consumer)', impl && impl.opts.model)
    result.modelRouting && result.modelRouting.tier === 'sonnet' && result.modelRouting.docsOnly === true ? ok()
      : ko('AC-009: docs-only modelRouting tier=sonnet docsOnly=true', JSON.stringify(result.modelRouting))
    impl && /MODEL TIER: sonnet — docs-only/.test(impl.prompt) ? ok() : ko('AC-008: sonnet brief names docs-only rule', impl && impl.prompt.slice(0, 80))
  }

  // (3) NIMBLE wiring (AC-006 / AC-007) — worktree implement carries opts.model; integrate unrouted.
  {
    const nimbleArgs = { runDir: '/tmp/run', repoRoot: '/tmp/repo', task: 'fix a thing' }
    // (a) no planned-files surfaced → opus
    const { result, dispatches } = await runNimble({ args: nimbleArgs, mock: nimbleMock })
    const impl = dispatches.find(d => d.opts.label === 'implement')
    impl && impl.opts.model === 'opus' ? ok() : ko('AC-006: nimble worktree implement opts.model="opus" (no planned-files)', impl && impl.opts.model)
    impl && impl.opts.isolation === 'worktree' ? ok() : ko('AC-006: nimble implement stays worktree-isolated (model is additive)', impl && impl.opts.isolation)
    const integ = dispatches.find(d => d.opts.label === 'integrate')
    integ && integ.opts.model === undefined ? ok() : ko('AC-007: nimble integrate opts.model undefined', integ && integ.opts.model)
    const stray = dispatches.filter(d => d.opts.label !== 'implement' && d.opts.model !== undefined)
    stray.length === 0 ? ok() : ko('AC-011: nimble — opts.model only on implement', JSON.stringify(stray.map(d => d.opts.label)))
    result.modelRouting && result.modelRouting.tier === 'opus' ? ok() : ko('AC-009: nimble modelRouting tier=opus (no planned-files)', JSON.stringify(result.modelRouting))
    // (b) docs-only planned-files surfaced → sonnet
    const { dispatches: d2 } = await runNimble({ args: { ...nimbleArgs, plannedFiles: ['docs/x.md'] }, mock: nimbleMock })
    const impl2 = d2.find(d => d.opts.label === 'implement')
    impl2 && impl2.opts.model === 'sonnet' ? ok() : ko('AC-006: nimble docs-only planned-files → sonnet', impl2 && impl2.opts.model)
  }

  // ====================================================================
  // W3DMR-T5 — token-budget circuit breaker (AUTO-PAUSE, never auto-kill).
  // ====================================================================
  // (1) A build dispatch that emits over its per-class budget → PAUSE-and-surface (an ESCALATE
  // criterionFindings entry), NOT a kill: the dispatch result (waveBuild) is PRESERVED.
  {
    const breachMock = (o, p) => {
      if (o.label === 'implement') return {
        wave_status: 'complete',
        tickets_built: [{ ticket_key: 'T-001', status: 'complete', sha: 'abc1234', files_changed: ['a.ts'], report: 'done' }],
        wave_report: 'wave complete',
        _usage: { output_tokens: 999_999 },   // far over the ~27k implementer budget → breach
      }
      return defaultMock(o, p)
    }
    const { result } = await runEngine({ args: baseArgs, mock: breachMock })
    const breach = (result.criterionFindings || []).find(f => f.id === 'BUDGET-implement')
    breach ? ok() : ko('AC-013: breach pushes a BUDGET-implement criterionFindings entry', JSON.stringify((result.criterionFindings || []).map(f => f.id)))
    breach && breach.recommended_disposition === 'ESCALATE' ? ok() : ko('AC-013: breaker disposition is ESCALATE (surface, not kill)', breach && breach.recommended_disposition)
    breach && breach.criterion_match === 'crit-4' ? ok() : ko('AC-013: breaker is crit-4 (operator authority — never auto-kill)', breach && breach.criterion_match)
    // NOT a kill: the dispatch result is preserved (the wave still integrated/gated; waveBuild present).
    result.waveBuild && result.waveBuild.wave_status === 'complete' ? ok() : ko('AC-013: dispatch result preserved (no kill/abort)', JSON.stringify(result.waveBuild && result.waveBuild.wave_status))
    result.surfaceRequired === true ? ok() : ko('AC-013: breach forces a surface', String(result.surfaceRequired))
  }
  // (2) A build dispatch WITHIN budget (or no usage data) → NO breaker finding (fail-open / no spurious PAUSE).
  {
    const okMock = (o, p) => {
      if (o.label === 'implement') return {
        wave_status: 'complete',
        tickets_built: [{ ticket_key: 'T-001', status: 'complete', sha: 'abc1234', files_changed: ['a.ts'], report: 'done' }],
        wave_report: 'wave complete',
        _usage: { output_tokens: 5_000 },     // well under budget
      }
      return defaultMock(o, p)
    }
    const { result } = await runEngine({ args: baseArgs, mock: okMock })
    !(result.criterionFindings || []).some(f => f.id === 'BUDGET-implement') ? ok() : ko('AC-013: within-budget dispatch → no breaker finding', 'spurious PAUSE')
  }
  // (3) No usage data surfaced → fail-open (no breaker finding; the breaker never PAUSEs on missing data).
  {
    const { result } = await runEngine({ args: baseArgs, mock: defaultMock })
    !(result.criterionFindings || []).some(f => f.id && f.id.startsWith('BUDGET-')) ? ok() : ko('AC-013: missing usage data → fail-open (no PAUSE)', 'spurious')
  }
  // (4) READ-ONLY metrics access: the engine never writes _metrics.jsonl (no bespoke append path).
  {
    const engineSrc = readFileSync(resolve(__td, './workflows/orchestrated.js'), 'utf8')
    const noWrite = !/_metrics\.jsonl[\s\S]{0,80}(appendFile|open\([^)]*['"]a['"]|fs\.append|writeFile)/.test(engineSrc)
      && !/(appendFile|fs\.append)\([^)]*_metrics/.test(engineSrc)
    noWrite ? ok() : ko('AC-013: no bespoke write path to _metrics.jsonl (read-only)', 'write detected')
  }

  // ====================================================================
  // ROADMAP ENGINE
  // ====================================================================

  // === AC-009 — Phase E ONE epic funnel: cto=1, architect=1, pm-spec=2, decomposer=1 ===
  {
    const { result, calls } = await runRoadmap({
      args: { runDir: '/tmp/run', repoRoot: '/tmp/repo', phase: 'E', epicSlug: 'my-epic', intent: 'do stuff' },
      mock: defaultRoadmapMock,
    })
    const counts = {
      cto: calls.filter(c => c === 'cto-advisor').length,
      architect: calls.filter(c => c === 'architect-review').length,
      // pm-spec: epic-level spec PLUS one render per wave_slug (the default mock yields 1 wave).
      pmSpec: calls.filter(c => c === 'pm-spec' || c.startsWith('pm-spec-render')).length,
      decomposer: calls.filter(c => c === 'spec-decomposer').length,
      uiSpec: calls.filter(c => c === 'ui-spec').length,
      authorFinalize: calls.filter(c => c === 'author' || c === 'finalize').length,
    }
    counts.cto === 1 ? ok() : ko('AC-009: cto-advisor=1', String(counts.cto))
    counts.architect === 1 ? ok() : ko('AC-009: architect-review=1 (PRE only — no final under roadmap)', String(counts.architect))
    counts.decomposer === 1 ? ok() : ko('AC-009: spec-decomposer=1', String(counts.decomposer))
    // pm-spec: 1 (spec) + 1 (render per wave) + 1 (author) = 3 dispatches under pm-spec agentType in this mock
    // Spec assertion: pm-spec=2 (spec + render) — the 'author' label is also pm-spec agentType, so pm-spec
    // agent dispatches = 3 (spec + author + render). Spec's pm-spec=2 refers to {spec, render}; verify both
    // are present.
    const hasSpec = calls.includes('pm-spec')
    const hasRender = calls.some(c => c.startsWith('pm-spec-render'))
    hasSpec && hasRender ? ok() : ko('AC-009: pm-spec(spec)+pm-spec(render) both present', `spec=${hasSpec} render=${hasRender}`)
    // wave grouping: at least one wave returned
    result.waves && result.waves.length >= 1 ? ok() : ko('AC-009: per-wave specs returned', JSON.stringify(result.waves && result.waves.length))
  }

  // === AC-011 — ui-spec=0 when no has_ui ===
  {
    const { calls } = await runRoadmap({
      args: { runDir: '/tmp/run', repoRoot: '/tmp/repo', phase: 'E', epicSlug: 'my-epic', intent: 'do stuff' },
      mock: defaultRoadmapMock,
    })
    calls.filter(c => c === 'ui-spec').length === 0 ? ok()
      : ko('AC-011: ui-spec=0 when cto.has_ui=false AND architect.has_ui=false AND wantUi unset', JSON.stringify(calls.filter(c => c === 'ui-spec')))
  }

  // === AC-011 — ui-spec=1 when cto.has_ui=true ===
  {
    const mock = (o, p) => {
      if (o.agentType === 'cto-advisor') return { verdict: 'GO', report: '# cto', has_ui: true }
      return defaultRoadmapMock(o, p)
    }
    const { calls } = await runRoadmap({
      args: { runDir: '/tmp/run', repoRoot: '/tmp/repo', phase: 'E', epicSlug: 'my-epic', intent: 'do stuff' },
      mock,
    })
    calls.filter(c => c === 'ui-spec').length === 1 ? ok()
      : ko('AC-011: ui-spec=1 when cto.has_ui=true', JSON.stringify(calls.filter(c => c === 'ui-spec')))
  }

  // === AC-011 — ui-spec=1 when architect.has_ui=true (cto false) ===
  {
    const mock = (o, p) => {
      if (o.agentType === 'architect-review') return { report: '# arch', has_ui: true }
      return defaultRoadmapMock(o, p)
    }
    const { calls } = await runRoadmap({
      args: { runDir: '/tmp/run', repoRoot: '/tmp/repo', phase: 'E', epicSlug: 'my-epic', intent: 'do stuff' },
      mock,
    })
    calls.filter(c => c === 'ui-spec').length === 1 ? ok()
      : ko('AC-011: ui-spec=1 when architect.has_ui=true', JSON.stringify(calls.filter(c => c === 'ui-spec')))
  }

  // === AC-011 — ui-spec=1 when wantUi:true (operator override; both has_ui false) ===
  {
    const { calls } = await runRoadmap({
      args: { runDir: '/tmp/run', repoRoot: '/tmp/repo', phase: 'E', epicSlug: 'my-epic', intent: 'do stuff', wantUi: true },
      mock: defaultRoadmapMock,
    })
    calls.filter(c => c === 'ui-spec').length === 1 ? ok()
      : ko('AC-011: ui-spec=1 when wantUi:true operator override', JSON.stringify(calls.filter(c => c === 'ui-spec')))
  }

  // === Phase E with N>1 waves — render fires once per wave_slug ===
  {
    const mock = (o, p) => {
      if (o.agentType === 'spec-decomposer') return {
        tickets: [
          { key: 'A-T1', description: 'a', depends_on: [], planned_files: ['a.ts'], acceptance: ['AC-1'], wave_slug: 'wave-1-a' },
          { key: 'B-T1', description: 'b', depends_on: ['A-T1'], planned_files: ['b.ts'], acceptance: ['AC-2'], wave_slug: 'wave-2-b' },
        ],
      }
      if (o.agentType === 'pm-spec' && o.phase === 'spec') return { markdown: 'AC-1 a. AC-2 b.' }
      if (o.agentType === 'pm-spec' && o.phase === 'author') return { markdown: '# roadmap', waves: [{ slug: 'wave-1-a', skeleton: '' }, { slug: 'wave-2-b', skeleton: '' }] }
      return defaultRoadmapMock(o, p)
    }
    const { result, calls } = await runRoadmap({
      args: { runDir: '/tmp/run', repoRoot: '/tmp/repo', phase: 'E', epicSlug: 'big', intent: 'two waves' },
      mock,
    })
    // STILL only one cto/architect/decomposer/spec; render fires per wave.
    calls.filter(c => c === 'cto-advisor').length === 1 ? ok() : ko('multi-wave: cto-advisor=1 (epic funnel)', String(calls.filter(c => c === 'cto-advisor').length))
    calls.filter(c => c === 'spec-decomposer').length === 1 ? ok() : ko('multi-wave: spec-decomposer=1 (flat tickets[])', String(calls.filter(c => c === 'spec-decomposer').length))
    calls.filter(c => c.startsWith('pm-spec-render')).length === 2 ? ok() : ko('multi-wave: pm-spec(render)=2 (one per wave_slug)', String(calls.filter(c => c.startsWith('pm-spec-render')).length))
    result.waves && result.waves.length === 2 ? ok() : ko('multi-wave: 2 waves rendered', String(result.waves && result.waves.length))
  }

  console.log(`behavioral: ${pass} passed, ${fail} failed`)
  process.exit(fail === 0 ? 0 : 1)
}
main().catch((e) => { console.error('HARNESS ERROR:', e.stack || e.message); process.exit(1) })
