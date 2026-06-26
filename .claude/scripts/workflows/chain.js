export const meta = {
  name: 'chain',
  description: 'v2 custom-chain preset (D6): run an OPERATOR-SUPPLIED ordered agent list as a sequence under the shared autonomy contract + consolidated surface (ADR-036). A thin layer over the T5a engine core — each agent is role-classified (think | implement | gate), runs in order seeing the accumulated prior outputs, gate-role agents return schema-forced findings, and the script computes the surface the orchestrator performs. Returns track:"chain"; the orchestrator persists via persist-run-artifacts.py (FLAG-1).',
  // A custom chain's phases are DYNAMIC (one per operator-supplied agent), so meta.phases cannot
  // enumerate them as a pure literal. The runtime calls phase(`${NN}-${agent}`) per step; per the
  // Workflow tool contract a phase() call with no matching meta entry simply gets its own progress
  // group (CR-005 — the mismatch is tolerated by design, confirmed by the T5c e2e run).
  phases: [
    { title: 'chain', detail: 'run the operator-supplied agent list in order (think -> implement -> gate, as specified)' },
  ],
}

// ===========================================================================
// THE v2 CUSTOM-CHAIN ENGINE (T5c). `/chain a,b,c` runs an arbitrary agent
// sequence the operator names. It is deliberately the THIN preset — the spike
// called it "trivial once the T5a harness exists" — so it reuses the nimble
// engine's contracts and schema VERBATIM rather than forking new machinery.
//
// THE FOUR STANDARDIZED ENGINE CONTRACTS (ADR-039), applied to the custom-chain shape:
//  1. Defensive args parse — `args` may arrive as a JSON string; `agents` may be
//     an array of strings or of {agent,role?} objects.
//  2. Returns a structured payload; the ORCHESTRATOR persists artifacts
//     (persist-run-artifacts.py, the persist_chain branch) — scripts have no FS
//     access; read-only agents (Explore) cannot Write.
//  3. The script COMPUTES the surface (criterionFindings + surfaceRequired,
//     ADR-018 crit-1..5); the ORCHESTRATOR disposes judgment-class findings (auto
//     APPLY/DEFER/DISMISS + decision log, ADR-105) and halts ONLY on an execution-class
//     block (ADR-036/ADR-105). A Workflow script cannot halt-and-wait.
//  4. Implement runs IN-PLACE. A custom chain is SEQUENTIAL (a -> b -> c), one
//     working tree, so there is no parallel-write hazard — the same reasoning as
//     nimble's contract 4. (Parallel-per-ticket worktrees are an orchestrated concern.)
//
// args: { runDir, repoRoot, task,
//         agents      : (string | {agent, role?})[]   // the operator's ordered chain
//         contextual? : string | string[]             // extra gate reviewers appended at the end
//       }
//   role (optional override): 'think' | 'implement' | 'gate'. When absent it is
//   inferred from the agent type (GATE_AGENTS -> gate; IMPLEMENT_AGENTS -> implement;
//   everything else -> think). The override lets the operator gate an agent the roster
//   classifies as think (e.g. force architect-review to emit findings).
// ===========================================================================

const _a = typeof args === 'string' ? JSON.parse(args) : (args || {})        // contract 1
const { runDir, repoRoot, task } = _a
if (!runDir || !repoRoot || !task) {
  throw new Error(`chain: missing required args (runDir/repoRoot/task). Got keys: ${Object.keys(_a).join(',') || '<none>'}`)
}

// --- normalize the operator's agent list (contract 1) ----------------------
let rawAgents = _a.agents
if (typeof rawAgents === 'string') {
  // tolerate a comma-joined string ("cto-advisor,implementer,code-reviewer") as a fallback shape
  rawAgents = rawAgents.split(',').map(s => s.trim()).filter(Boolean)
}
if (!Array.isArray(rawAgents) || !rawAgents.length) {
  throw new Error(`chain: 'agents' must be a non-empty array (or comma-joined string) of agent names. Got: ${JSON.stringify(_a.agents)}`)
}

// contextual reviewers (parity with nimble.js) — appended to the chain as gate-role agents
let contextual = _a.contextual || []
if (typeof contextual === 'string') contextual = [contextual]
if (!Array.isArray(contextual)) {                                            // CR-001: structured error, not a bare TypeError
  throw new Error(`chain: 'contextual' must be a string or array of agent names. Got: ${JSON.stringify(_a.contextual)}`)
}

// --- role roster -----------------------------------------------------------
// A small, conservative classification. Anything not listed defaults to 'think'
// (free-form analysis fed forward). The operator can override per-agent.
const GATE_AGENTS = new Set([
  'code-reviewer', 'spec-conformance', 'security-auditor', 'ui-review',
  'db-migration-reviewer', 'performance-reviewer', 'accessibility-auditor',
])
const IMPLEMENT_AGENTS = new Set([
  'implementer', 'frontend-implementer', 'backend-implementer',
  'nimble-implementer', 'wave-implementer',
])
const VALID_ROLES = new Set(['think', 'implement', 'gate'])
// agent type shape guard — agentType flows into the Agent tool's registry lookup; reject anything
// that isn't a plausible agent name before dispatch (defence-in-depth, mirrors orchestrated.js).
const AGENT_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

function inferRole(name) {
  if (GATE_AGENTS.has(name)) return 'gate'
  if (IMPLEMENT_AGENTS.has(name)) return 'implement'
  return 'think'
}

// build the ordered chain spec: [{ agent, role, label }, ...]
const chainSpec = []
const shapeErrors = []
rawAgents.forEach((entry, i) => {
  const agentType = typeof entry === 'string' ? entry : (entry && entry.agent)
  if (!agentType || typeof agentType !== 'string' || !AGENT_RE.test(agentType)) {
    shapeErrors.push(`agents[${i}] is not a valid agent name: ${JSON.stringify(entry)}`)
    return
  }
  let role = (typeof entry === 'object' && entry.role) ? entry.role : inferRole(agentType)
  if (!VALID_ROLES.has(role)) {
    shapeErrors.push(`agents[${i}] (${agentType}) has invalid role '${role}' (allowed: ${[...VALID_ROLES].join('/')})`)
    return
  }
  chainSpec.push({ agent: agentType, role })
})
for (const rev of contextual) {
  if (typeof rev !== 'string' || !AGENT_RE.test(rev)) {
    shapeErrors.push(`contextual reviewer is not a valid agent name: ${JSON.stringify(rev)}`)
    continue
  }
  chainSpec.push({ agent: rev, role: 'gate' })
}
if (shapeErrors.length) {
  throw new Error(`chain: malformed agent list — ${shapeErrors.join('; ')}`)
}
// stable, unique, ordered step labels: 01-cto-advisor, 02-implementer, 03-code-reviewer
const pad = n => String(n).padStart(2, '0')
chainSpec.forEach((s, i) => { s.label = `${pad(i + 1)}-${s.agent}` })

// --- schema + crit instruction (reused VERBATIM from nimble.js) ------------
const FINDINGS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['verdict', 'findings'],
  properties: {
    verdict: { type: 'string' },
    summary: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['id', 'severity', 'criterion_match', 'recommended_disposition', 'detail'],
        properties: {
          id: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'high', 'medium', 'low', 'nit'] },
          criterion_match: { type: 'string', enum: ['none', 'crit-1', 'crit-2', 'crit-3', 'crit-4', 'crit-5'] },
          recommended_disposition: { type: 'string', enum: ['APPLY', 'DEFER', 'DISMISS', 'ESCALATE'] },
          detail: { type: 'string' },
        },
      },
    },
  },
}
const CRIT = `For each finding set criterion_match per ADR-018 (none = auto-disposable; ` +
  `crit-1 architecture / crit-2 scope / crit-3 security / crit-4 operator-authority / crit-5 ambiguity) ` +
  `and recommended_disposition (APPLY/DEFER/DISMISS/ESCALATE).`

// ---------------------------------------------------------------------------
// Run the chain in order. Each agent sees the task + the accumulated outputs of
// every prior step (the "front-loaded thinking -> implement -> gate" flow). This
// is a sequence (a -> b -> c), not a fan-out: a custom chain is inherently ordered
// and each step's value is informed by the ones before it.
// ---------------------------------------------------------------------------
const steps = []                 // ordered per-agent results (for the return + persist)
const transcript = []            // accumulated context strings fed to later agents
const allFindings = []
const criterionFindings = []

function harvest(label, agent, res) {
  if (res && Array.isArray(res.findings)) {
    for (const f of res.findings) {
      const tagged = { ...f, gate: agent, step: label }
      allFindings.push(tagged)
      if (f.criterion_match && f.criterion_match !== 'none') criterionFindings.push(tagged)
    }
  }
}

// ADR-083 D3 — transcript window. The 2 most recent steps stay verbatim (adjacent-step reasoning is
// the value of a chain); older steps collapse their BODY to its first 200 chars + an ellipsis marker,
// keeping each entry's `### {label} ({role})` header line intact. Pure string slicing, order preserved.
// (Gate entries are already short — `verdict=... — {<=300-char summary}` — so the digest barely touches them.)
const TRANSCRIPT_VERBATIM = 2
const DIGEST_CHARS = 200
function digestEntry(entry) {
  const nl = entry.indexOf('\n')
  if (nl === -1) return entry                              // header-only entry (no body) — leave as-is
  const header = entry.slice(0, nl)
  const body = entry.slice(nl + 1)
  if (body.length <= DIGEST_CHARS) return entry            // already short — no point digesting
  return `${header}\n${body.slice(0, DIGEST_CHARS)} […digested]`
}
function priorContext() {
  if (!transcript.length) return '(this is the first step in the chain)'
  const cut = Math.max(0, transcript.length - TRANSCRIPT_VERBATIM)
  const windowed = transcript.map((e, i) => i < cut ? digestEntry(e) : e)
  return `Prior steps in this chain (honour their conclusions):\n\n${windowed.join('\n\n---\n\n')}`
}

for (const step of chainSpec) {
  phase(step.label)
  const ctx = priorContext()

  if (step.role === 'implement') {
    // contract 4: in-place (sequential chain, single working tree, no parallel-write hazard)
    const report = await agent(
      `Custom-chain IMPLEMENT step (${step.agent}) in repo ${repoRoot}. Read prompt.md / spec.md (if present) ` +
      `from ${runDir} yourself.\n\nTASK:\n${task}\n\n${ctx}\n\n` +
      `Edit files IN PLACE in the main working tree (do NOT create a git worktree). Implement end-to-end, run your ` +
      `own verification, and return a COMPLETION_REPORT (what you created/changed, verification output, scope note). ` +
      `If this exceeds the chain's intended scope, REFUSE with rationale.`,
      { label: step.label, phase: step.label, agentType: step.agent }
    )
    steps.push({ label: step.label, agent: step.agent, role: step.role, text: report || null })
    transcript.push(`### ${step.label} (implement)\n${report || '(agent returned null — see surface)'}`)
    if (report == null) {
      criterionFindings.push({
        gate: step.agent, step: step.label, id: `CHAIN-${step.label}`,
        severity: 'high', criterion_match: 'crit-1', recommended_disposition: 'ESCALATE',
        detail: `chain step ${step.label} (${step.agent}, implement) returned null (agent died) — chain cannot continue cleanly`,
      })
    }

  } else if (step.role === 'gate') {
    const res = await agent(
      `Custom-chain GATE step (${step.agent}) in repo ${repoRoot}. Review the work produced so far in this chain ` +
      `(inspect via git diff / reading files).\n\nTASK:\n${task}\n\n${ctx}\n\n` +
      `Return verdict + findings per the schema. ${CRIT}`,
      { label: step.label, phase: step.label, agentType: step.agent, schema: FINDINGS_SCHEMA }
    )
    steps.push({ label: step.label, agent: step.agent, role: step.role, verdict: res ? res.verdict : null, summary: res ? (res.summary || '') : '', findings: res ? (res.findings || []) : [] })
    harvest(step.label, step.agent, res)
    transcript.push(`### ${step.label} (gate)\nverdict=${res ? res.verdict : 'NULL'} — ${res ? (res.summary || '').slice(0, 300) : 'agent died'}`)
    if (res == null) {
      // a gate that died did NOT clean-pass — surface it (mirrors nimble's CR-002 philosophy)
      criterionFindings.push({
        gate: step.agent, step: step.label, id: `CHAIN-${step.label}`,
        severity: 'high', criterion_match: 'crit-1', recommended_disposition: 'ESCALATE',
        detail: `chain gate ${step.label} (${step.agent}) returned null (agent died) — gate did not pass`,
      })
    }

  } else { // think
    const out = await agent(
      `Custom-chain THINKING step (${step.agent}) in repo ${repoRoot}.\n\nTASK:\n${task}\n\n${ctx}\n\n` +
      `Produce your analysis/output for this step. Conclusions the downstream chain steps can act on. ` +
      `If you are an Explore agent: report data shapes, file conventions, and existing patterns. Conclusions only.`,
      { label: step.label, phase: step.label, agentType: step.agent }
    )
    steps.push({ label: step.label, agent: step.agent, role: step.role, text: out || null })
    transcript.push(`### ${step.label} (think)\n${out || '(agent returned null)'}`)
  }
}

// --- consolidated-surface computation (contract 3; ADR-036) ----------------
log(`chain complete: ${chainSpec.length} step(s) [${chainSpec.map(s => `${s.agent}:${s.role}`).join(' -> ')}]` +
    ` | ${allFindings.length} finding(s), ${criterionFindings.length} criterion-matched (surface-worthy)`)

return {
  track: 'chain',                                  // explicit track => persist routes deterministically
  agents: chainSpec.map(s => ({ agent: s.agent, role: s.role, label: s.label })),
  steps,
  allFindings,
  criterionFindings,
  surfaceRequired: criterionFindings.length > 0,   // advisory: orchestrator disposes judgment-class, halts only on execution-block (ADR-105)
}
