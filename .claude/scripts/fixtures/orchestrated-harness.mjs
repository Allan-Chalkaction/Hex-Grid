// Behavioral test harness for the v2 orchestrated engine (core/scripts/workflows/orchestrated.js).
//
// The engine is a Workflow script: its runtime provides agent()/parallel()/phase()/log()/args as
// globals and wraps the body so top-level await + return are legal. node --check parses it but cannot
// RUN it — so the engine's control flow had no behavioral net (only the Python helpers were tested).
//
// This harness reproduces the runtime: it strips the `export const meta` (read separately by the real
// runtime), wraps the remaining body in an async function via new Function(), and injects mock
// agent()/parallel()/phase()/log()/args. It returns { result, calls } where `calls` is the ordered
// list of agent labels/types dispatched — so a test can assert BOTH the returned payload shape and the
// dispatch sequence. The ONE thing it cannot validate is real native-worktree isolation (the engine
// asks an `implementer` to commit in a worktree); that remains the live-run gate.
//
// Usage:
//   import { runEngine } from './orchestrated-harness.mjs'
//   const { result, calls } = await runEngine({ args, mock })
//   where `mock(opts) -> structuredReturn` decides each agent's return (by opts.label/agentType).

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const __dir = dirname(fileURLToPath(import.meta.url))
const ENGINE = resolve(__dir, '../workflows/orchestrated.js')

// A reasonable default mock: a clean single-ticket GO/SOUND/CONFORMS happy path. Tests override per-case.
// ADR-062 (T-102): the wave-builder is ONE implementer dispatched as label 'implement' that returns
// WAVE_BUILD_SCHEMA (wave_status / tickets_built[] / wave_report). Per-ticket history is preserved inside
// tickets_built[], not via per-ticket dispatches.
export function defaultMock(opts = {}) {
  const t = opts.agentType
  const label = opts.label || ''
  if (t === 'cto-advisor') return { recommendation: 'GO', rationale: 'sound approach', evaluation_markdown: '# cto' }
  if (t === 'architect-review' && label.includes('pre')) return { verdict: 'SOUND', adr_markdown: '# ADR\nbuild it', summary: 'sound' }
  if (t === 'architect-review') return { verdict: 'APPROVE', findings: [], summary: 'composes' }
  if (t === 'examiner') return { verdict: 'SOUND', findings: [], summary: '# examine — sound' }  // PEC-T14: clean default
  if (t === 'pm-spec') return { spec_markdown: 'Spec.\nAC-1 the thing works.', summary: 'spec' }
  if (t === 'ui-spec') return { ui_spec_markdown: '# UI', summary: 'ui' }
  if (t === 'spec-decomposer') return { tickets: [{ key: 'T-001', description: 'do it', depends_on: [], planned_files: ['a.ts'], acceptance: ['AC-1'] }] }
  if (t === 'Explore') return 'codebase findings'
  if (label === 'implement') {
    // The wave-builder: returns WAVE_BUILD_SCHEMA. Default — a single-ticket wave.
    return {
      wave_status: 'complete',
      tickets_built: [{ ticket_key: 'T-001', status: 'complete', sha: 'abc1234', files_changed: ['a.ts'], report: 'COMPLETION_REPORT' }],
      wave_report: 'wave complete',
    }
  }
  if (label === 'integrate') return { status: 'integrated', integrated_head: 'def5678', base_sha: 'abc1234', merged: ['T-001'], stale: [], report: 'verified' }
  if (t === 'code-reviewer' || t === 'spec-conformance' || label.startsWith('gate:')) return { verdict: 'CONFORMS', findings: [], summary: 'conforms' }
  return { verdict: 'APPROVE', findings: [], summary: 'ok' }
}

export async function runEngine({ args, mock }) {
  const decide = mock || defaultMock
  const calls = []
  let src = readFileSync(ENGINE, 'utf8')
  // Strip the ESM export the real runtime reads out-of-band; keep everything else verbatim.
  src = src.replace(/export const meta\s*=\s*\{[\s\S]*?\n\}\n/, 'const meta = {};\n')
  const body = `return (async () => {\n${src}\n})();`

  const agent = async (prompt, opts = {}) => {
    calls.push(opts.label || opts.agentType || '?')
    return decide(opts, prompt)
  }
  const parallel = async (thunks) => Promise.all(thunks.map((f) => f()))
  const phase = () => {}
  const log = () => {}

  // eslint-disable-next-line no-new-func
  const fn = new Function('agent', 'parallel', 'phase', 'log', 'args', 'meta', body)
  const result = await fn(agent, parallel, phase, log, args, {})
  return { result, calls }
}
