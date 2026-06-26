// Behavioral test harness for the v2 ROADMAP engine (core/scripts/workflows/roadmap.js).
// Mirrors orchestrated-harness.mjs: strips the meta export, wraps the body, and injects mock
// agent()/parallel()/phase()/log()/args. Returns { result, calls } where `calls` is the ordered list
// of dispatched agent labels — so a test can assert dispatch counts and sequence.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const __dir = dirname(fileURLToPath(import.meta.url))
const ENGINE = resolve(__dir, '../workflows/roadmap.js')

// Default mock: a clean Phase E single-wave epic, has_ui=false everywhere, planner LOCKs at self-QA.
export function defaultRoadmapMock(opts = {}) {
  const t = opts.agentType
  const label = opts.label || ''
  if (label === 'intent-capture') return { markdown: '# captured epic intent\nThe grounded intent from the jam.' }
  if (t === 'cto-advisor') return { verdict: 'GO', report: '# cto', has_ui: false }
  if (t === 'architect-review') return { report: '# architect', has_ui: false }
  if (t === 'ui-spec') return { report: '# ui-spec' }
  if (t === 'pm-spec' && opts.phase === 'spec') return { markdown: '# Epic spec\nAC-1 do thing.' }
  if (t === 'spec-decomposer') return {
    tickets: [
      { key: 'E-T1', description: 'do the thing', depends_on: [], planned_files: ['a.ts'], acceptance: ['AC-1'], wave_slug: 'wave-1-do' },
    ],
  }
  if (label.startsWith('pm-spec-render')) return { promptsMarkdown: '# build prose' }
  if (t === 'pm-spec') return { markdown: '# roadmap\n## wave-1-do\nthe wave', waves: [{ slug: 'wave-1-do', skeleton: 'wave-1 skel' }] }
  if (t === 'planner') return { disposition: 'LOCK', report: '# self-qa', verified: true, tunings: [] }
  if (t === 'examiner') return { verdict: 'SOUND', findings: [], summary: '# examine — sound' }  // PEC-T13: clean default
  if (t === 'Explore') return 'research findings'
  return { report: 'ok' }
}

export async function runRoadmap({ args, mock }) {
  const decide = mock || defaultRoadmapMock
  const calls = []
  let src = readFileSync(ENGINE, 'utf8')
  src = src.replace(/export const meta\s*=\s*\{[\s\S]*?\n\}\n/, 'const meta = {};\n')
  // ADR-065 (amended 2026-06-13): runIntentCapture is now INLINE in roadmap.js (no cross-file import —
  // the Workflow runtime forbids imports). The new Function() body therefore defines it itself; the
  // harness exercises the REAL inlined capture path (no import-strip, no helper injection).
  const body = `return (async () => {\n${src}\n})();`

  const agent = async (prompt, opts = {}) => {
    calls.push(opts.label || opts.agentType || '?')
    return decide(opts, prompt)
  }
  const parallel = async (thunks) => Promise.all(thunks.map((f) => f()))
  const phases = []
  const phase = (name) => { phases.push(name) }
  const log = () => {}

  // eslint-disable-next-line no-new-func
  const fn = new Function('agent', 'parallel', 'phase', 'log', 'args', 'meta', body)
  const result = await fn(agent, parallel, phase, log, args, {})
  return { result, calls, phases }
}
