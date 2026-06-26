export const meta = {
  name: 'decompose-jams',
  description: 'Parallel fan-out decomposition of operator-promoted jams (the /bulk-decompose-jams --auto path). For each jam flagged `decompose: ready`, runs the funnel cto-advisor -> architect-review -> [ui-spec] -> pm-spec in an independent pipeline branch, all jams concurrent (engine concurrency-capped). Advisor-only (no implementers). Returns per-jam spec + paste-ready prompts as strings; the ORCHESTRATOR persists them to jam-<slug>/decomposition/ (ADR-039 contract 2 — scripts have no FS).',
  phases: [
    { title: 'analyze', detail: 'per jam: cto-advisor (strategic/feasibility) -> architect-review (soundness, ADR needs, foundational cut)' },
    { title: 'slice', detail: 'per jam: [ui-spec if UI] -> pm-spec authors the spec + per-ticket prompts' },
  ],
}

// ===========================================================================
// decompose-jams — the parallel set-and-forget decompose pass.
//
// This is "roadmap's Phase-W funnel, minus the per-round operator tuning,
// fanned out across every promoted jam at once." Readiness is DECLARED by the
// operator (`decompose: ready`); the orchestrator computes the ready set from
// bulk-decompose-plan.py and passes it in. The script never guesses readiness.
//
// FOUR ENGINE CONTRACTS (ADR-039, mirrored from nimble.js):
//  1. Defensive args parse — `args` may arrive as a JSON string.
//  2. Returns a structured payload; the ORCHESTRATOR persists (scripts have no
//     FS access). Each branch RETURNS spec_md/prompts_md as strings; the
//     orchestrator writes them to jam-<slug>/decomposition/.
//  3. The script computes; the orchestrator performs any halt. A Workflow runs
//     to completion in the background — it cannot pause mid-run for per-jam
//     review. So the two hard halts (missing-ADR crit-1, scope-shift crit-2)
//     are RETURNED as status:'blocked'/'scope_shift' and surfaced by the
//     orchestrator in the single fan-in review.
//  4. No isolation needed — every agent is advisor-tier and read-only; the
//     script writes nothing and the agents only Read. No worktrees.
//
// args: { repoRoot, target?, jams: [{ slug, jamDir, briefPath, note? }] }
//   target: 'bypass' (default) -> paste-ready prompts; 'orchestrated' -> # Wave schema.
//   jams:   the READY/STALE set from bulk-decompose-plan.py (NOT recomputed here).
// ===========================================================================

const _a = typeof args === 'string' ? JSON.parse(args) : (args || {})        // contract 1
const { repoRoot } = _a
const target = _a.target === 'orchestrated' ? 'orchestrated' : 'bypass'
const jams = Array.isArray(_a.jams) ? _a.jams : []
if (!repoRoot || jams.length === 0) {
  throw new Error(`decompose-jams: missing required args (repoRoot + non-empty jams[]). Got keys: ${Object.keys(_a).join(',') || '<none>'}`)
}

// --- schemas -------------------------------------------------------------
const ANALYZE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['status', 'has_ui', 'strategic', 'arch_summary'],
  properties: {
    status: { type: 'string', enum: ['ok', 'blocked'] },   // blocked = missing-ADR / unresolvable arch (crit-1)
    blockReason: { type: 'string' },
    has_ui: { type: 'boolean' },                            // does this jam have a non-trivial UI surface?
    adr_needs: { type: 'array', items: { type: 'string' } },
    strategic: { type: 'string' },                         // cto-advisor's feasibility/strategic read
    arch_summary: { type: 'string' },                      // architect's boundaries + foundational cut
  },
}
const SLICE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['status', 'spec_md', 'prompts_md', 'ticket_count'],
  properties: {
    status: { type: 'string', enum: ['ok', 'scope_shift'] }, // scope_shift = work materially exceeds the brief (crit-2)
    scope_note: { type: 'string' },
    spec_md: { type: 'string' },      // the buildable spec (with AC-NNN) — orchestrator persists
    prompts_md: { type: 'string' },   // one paste-ready ticket prompt per slice — orchestrator persists
    ticket_count: { type: 'integer' },
  },
}

const SLICE_FORMAT = target === 'orchestrated'
  ? `Emit prompts_md in the parseable \`# Wave:\` ticket schema (### KEY: title blocks with depends_on / ` +
    `planned_files (disjoint, non-empty) / gate_recommendations / manual_review_required / a description block; ` +
    `keys match ^[A-Z][A-Z0-9]*-[A-Z0-9]+$, single hyphen).`
  : `Emit prompts_md as paste-ready bypass ticket prompts (bypass-mode-prompt-authoring / feature-decomposition ` +
    `format): one block per slice with the autonomy framing, the 4-tier halt protocol, per-ticket gate recos, ` +
    `and \`Isolation: worktree\`.`

// --- the per-jam funnel (independent pipeline branches) -------------------
// Stage 1: cto-advisor (strategic) -> architect-review (soundness + ADR gate).
async function analyzeStage(jam) {
  const cto = await agent(
    `Repo: ${repoRoot}. Read the converged jam brief at ${jam.briefPath} (and other files under ${jam.jamDir} as needed). ` +
    `Give a strategic/feasibility read on building this jam: is the approach sound, what are the risks, what's out of scope. ` +
    (jam.note ? `Operator note (honor it): ${jam.note}. ` : '') +
    `Conclusions only.`,
    { label: `cto:${jam.slug}`, phase: 'analyze', agentType: 'cto-advisor' }
  )
  const analysis = await agent(
    `Repo: ${repoRoot}. Read the converged jam brief at ${jam.briefPath} (and other files under ${jam.jamDir} as needed). ` +
    `The cto-advisor's read:\n${cto}\n\n` +
    `Produce the foundational architectural cut for decomposing this jam into tickets: component boundaries, the ticket ` +
    `seams, and any ADRs the work needs. Set has_ui if the jam has a non-trivial UI surface. ` +
    `If the work requires a genuinely NEW architectural decision with NO governing ADR, set status='blocked' and put the ` +
    `reason in blockReason (ADR-018 crit-1) — do NOT decompose against a missing ADR. Otherwise status='ok'.`,
    { label: `arch:${jam.slug}`, phase: 'analyze', agentType: 'architect-review', schema: ANALYZE_SCHEMA }
  )
  return { jam, cto, ...analysis }
}

// Stage 2: [ui-spec if UI] -> pm-spec (slicer/integrator). Carries 'blocked' through untouched.
async function sliceStage(a, jam) {
  if (!a || a.status === 'blocked') {
    return { slug: jam.slug, status: 'blocked', blockReason: (a && a.blockReason) || 'analyze failed',
      findings: { strategic: a && a.strategic, arch_summary: a && a.arch_summary, adr_needs: (a && a.adr_needs) || [] } }
  }
  let ui = null
  if (a.has_ui) {
    ui = await agent(
      `Repo: ${repoRoot}. Read the jam brief at ${jam.briefPath}. Architect's cut:\n${a.arch_summary}\n\n` +
      `Produce concrete visual requirements + error-state UX for this jam's UI surface (tokens, states, anti-patterns).`,
      { label: `ui:${jam.slug}`, phase: 'slice', agentType: 'ui-spec' }
    )
  }
  const slice = await agent(
    `Repo: ${repoRoot}. Read the jam brief at ${jam.briefPath} (and ${jam.jamDir} as needed). ` +
    `Architect's cut:\n${a.arch_summary}\n` + (ui ? `UI spec:\n${ui}\n` : '') +
    (jam.note ? `\nOperator scope note (honor it):\n${jam.note}\n` : '') +
    `\nAs integrator + slicer: author the buildable spec (mint AC-NNN for every acceptance criterion) and slice it into ` +
    `tickets per core/reference/ticket-slicing-doctrine.md (vertical slices, <= ~10 files each, observable acceptance in ` +
    `3-5 bullets, disjoint planned_files across parallel tickets, direct depends_on edges). ${SLICE_FORMAT}\n` +
    `Put the spec in spec_md and the prompts in prompts_md. If the actual scope materially exceeds what the brief implies ` +
    `(a real scope shift, not just more tickets than expected), set status='scope_shift' and explain in scope_note; else 'ok'.`,
    { label: `pm-spec:${jam.slug}`, phase: 'slice', agentType: 'pm-spec', schema: SLICE_SCHEMA }
  )
  return {
    slug: jam.slug,
    status: slice.status === 'scope_shift' ? 'scope_shift' : 'decomposed',
    spec_md: slice.spec_md,
    prompts_md: slice.prompts_md,
    ticket_count: slice.ticket_count,
    scope_note: slice.scope_note || '',
    findings: { strategic: a.strategic, arch_summary: a.arch_summary, ui_spec: ui, adr_needs: a.adr_needs || [] },
  }
}

log(`decompose-jams: ${jams.length} promoted jam(s), target=${target} — fanning out the funnel per jam`)
const results = (await pipeline(jams, analyzeStage, sliceStage)).filter(Boolean)

// contract 2/3: the orchestrator persists spec_md/prompts_md per jam to jam-<slug>/decomposition/ and
// surfaces any status:'blocked' (missing-ADR) or 'scope_shift' in the single fan-in review.
const blocked = results.filter(r => r.status === 'blocked').map(r => r.slug)
const scopeShift = results.filter(r => r.status === 'scope_shift').map(r => r.slug)
return {
  track: 'decompose-jams',
  target,
  results,
  surfaceRequired: blocked.length > 0 || scopeShift.length > 0,
  blocked,
  scopeShift,
}
