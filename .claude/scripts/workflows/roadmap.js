export const meta = {
  name: 'roadmap',
  description: 'v2 roadmap preset (ADR-055): the advisory planning funnel ON THE ENGINE. Phase E (research -> cto -> author -> planner self-QA -> finalize) authors the wave roadmap AND, autonomously, FANS OUT — it runs the Phase W funnel for EVERY authored wave, SEQUENTIALLY (each wave sees the prior waves it builds on), so one /roadmap plans the whole epic end-to-end. Phase W (cto -> architect -> [ui-spec] -> pm-spec(spec) -> spec-decomposer -> graph-validate -> author -> self-QA -> finalize) slices via the ONE canonical slicer (spec-decomposer, ADR-044/047/048) so a roadmap-authored wave matches what /orchestrated would produce. Autonomous-to-completion (ADR-054); dispatches ONLY advisor/authoring agents (no implementers, no worktrees, no merges). RETURNS a structured payload the orchestrator persists via persist-run-artifacts.py (FLAG-1, contract 2) — for a fan-out run that is the roadmap + one wave spec per authored wave. The orchestrator drives no funnel ceremony.',
  phases: [
    { title: 'intent-capture', detail: 'Phase E first step: capture/ground the epic intent from the jam (pm-spec) before any phase — escape-hatch: curated/jam-direct short-circuit (ADR-065)' },
    { title: 'research', detail: 'Phase E only: Explore agents ground the intent + correct code-blind claims' },
    { title: 'decompose', detail: 'cto-advisor (E) / cto+architect+ui-spec (W) produce the breakdown' },
    { title: 'spec', detail: 'Phase W: pm-spec authors the buildable spec (AC-NNN) BEFORE slicing' },
    { title: 'decompose-tickets', detail: 'Phase W: spec-decomposer slices the spec into tickets[] (ADR-044/048) + graph-validate' },
    { title: 'author', detail: 'pm-spec/planner authors the roadmap|wave markdown — NOT the orchestrator' },
    { title: 'self-qa', detail: 'planner re-verifies by view, recommends LOCK/CONTINUE + tunings' },
    { title: 'finalize', detail: 'autonomous: fold tunings -> finalized markdown in the return (ADR-054)' },
    { title: 'fan-out', detail: 'Phase E autonomous: run the Phase W funnel for each authored wave, SEQUENTIALLY' },
  ],
}

// ===========================================================================
// THE v2 ROADMAP ENGINE (ADR-055, the structural half of ADR-054).
// Mirrors nimble.js/orchestrated.js and honours the four ADR-039 contracts:
//  1. Defensive args parse.
//  2. Returns a structured payload; the ORCHESTRATOR persists (persist_roadmap)
//     — agents can't write the canonical docs/step-3-specs file, so the AUTHORING agent
//     returns the markdown as a string and persist writes it. This is what keeps
//     the orchestrator light AND fixes role-purity (authoring lives in an agent).
//     A fan-out Phase E run returns roadmapMarkdown + waves[]{slug,waveSpecMarkdown,
//     wavePromptsMarkdown}; the orchestrator persists the roadmap then loops the
//     existing per-wave persist (no Python change). Collapsing that persist loop
//     is the separate persist-bridge follow-up.
//  3. The script computes surfaceRequired; the orchestrator performs any halt.
//     Autonomous (ADR-054): surfaceRequired is true ONLY on an ADR-018 interrupt
//     or in --attended mode (return the round, let the orchestrator present it).
//  4. No worktree / no implementer — advisory funnel only.
//
// args: { runDir, repoRoot, phase: 'E'|'W', epicSlug, waveSlug?, intent, attended?, fanOut?, waves? }
//   intent: the seeded epic intent (E) or the wave's fat skeleton (W) — verbatim.
//   attended: legacy ADR-030 round loop — return draft+QA WITHOUT finalizing. In attended Phase E
//             the run STOPS at the roadmap round (no fan-out) so the operator can tune the roadmap
//             before any wave is planned; fan-out is an autonomous-Phase-E behavior.
//   fanOut: Phase E only; default true. false => author the roadmap only (no per-wave Phase W).
//   waves:  optional [{slug, skeleton}] override of the wave work-list (else taken from the author).
// ===========================================================================

const _a = typeof args === 'string' ? JSON.parse(args) : (args || {})        // contract 1
const { runDir, repoRoot, epicSlug } = _a
const rmPhase = _a.phase                          // 'E' | 'W' — named rmPhase to avoid shadowing the phase() hook
const intent = _a.intent || ''
// ADR-065: Phase E captures intent from the jam by default ('capture'); 'curated'/'jam-direct' short-circuit
// to the verbatim `intent` arg (back-compat — /orchestrate-epic fan-out, operator paste). Phase W never reaches
// the capture call (the call site is inside `if (rmPhase === 'E')`), so the default is harmless there.
const intentSource = _a.intentSource || 'capture'
const waveSlug = _a.waveSlug || null
const attended = !!_a.attended
const fanOut = _a.fanOut !== false                // Phase E: default ON (one /roadmap plans the whole epic)
if (!runDir || !repoRoot || !rmPhase || !epicSlug) {
  throw new Error(`roadmap: missing required args (runDir/repoRoot/phase/epicSlug). Got keys: ${Object.keys(_a).join(',') || '<none>'}`)
}
if (rmPhase !== 'E' && rmPhase !== 'W') throw new Error(`roadmap: phase must be 'E' or 'W', got '${rmPhase}'`)
if (rmPhase === 'W' && !waveSlug) throw new Error(`roadmap: phase 'W' requires waveSlug`)

const SLUG_RE = /^[a-z0-9][a-z0-9-]*$/
if (!SLUG_RE.test(epicSlug)) throw new Error(`roadmap: epicSlug must be a kebab slug, got '${epicSlug}'`)
if (waveSlug && !SLUG_RE.test(waveSlug)) throw new Error(`roadmap: waveSlug must be a kebab slug, got '${waveSlug}'`)
// SA-002 (ADR-103 W2 security review): jamSlug builds a docs/step-2-planning/jam-<slug>/ read path (line ~314,
// and the W2 author-glob) — validate it to the same kebab-only shape so an operator-supplied '../' cannot point
// the read-only jam glob outside the planning tree. Defense-in-depth; the gate's default JAM_DIR uses epicSlug.
if (_a.jamSlug && !SLUG_RE.test(_a.jamSlug)) throw new Error(`roadmap: jamSlug must be a kebab slug, got '${_a.jamSlug}'`)

// Optional per-file byte-size map for the wave context-budget estimator (ADR-086 D2). Scripts have no
// FS access (ADR-039 contract 2) — the orchestrator/skill passes byte sizes via args where it has them;
// absent => the estimator falls back to a per-file constant and says so in the WARN text.
const fileBytes = (_a.fileBytes && typeof _a.fileBytes === 'object') ? _a.fileBytes : {}

// ---------------------------------------------------------------------------
// WAVE CONTEXT-BUDGET ESTIMATOR (ADR-086 D2) — deterministic, in-engine. Identical copy to
// orchestrated.js (scripts are self-contained; no cross-file imports — ADR-039). Predicts a wave's
// implementer context consumption so an over-budget candidate wave raises a WARN AT PLANNING TIME
// (ADR-086 D4: WARN-and-surface, never a hard block — the slicer proposes the split at a dependency
// seam). Constants are STARTING values; T4.2 telemetry (measure-run.sh, ADR-086 D3) calibrates them.
const BUDGET_FACTORS = {
  READ_FACTOR: 3,               // planned files get read, re-read, and reasoned over (T4.2-calibrated)
  FIXED_OVERHEAD: 60_000,       // spec + findings + protocol + system prompt, per wave (tokens)
  EXPECTED_OUTPUT_PER_TICKET: 15_000,  // implementer write/think output per ticket (tokens)
  EFFECTIVE_TASK_CONTEXT: 80_000,  // ADR-086 D1 (Wave-1 landing zone): calibrated effective reasoning/code context ON TOP of FIXED_OVERHEAD; telemetry-tuned per D3
  PINNED_WINDOW: 1_000_000,     // Opus 4.8[1m] — context-window metadata (no longer drives the budget; see EFFECTIVE_TASK_CONTEXT)
  FALLBACK_FILE_BYTES: 8_192,   // per-file byte estimate when no byte data is supplied via args
}
// (planned_file_bytes / 4) * READ_FACTOR + FIXED_OVERHEAD + EXPECTED_OUTPUT_PER_TICKET * ticketCount.
function estimateWaveTokens(tickets, fb) {
  const F = BUDGET_FACTORS
  const bytesMap = (fb && typeof fb === 'object') ? fb : {}
  let totalBytes = 0, usedFallback = false, fileCount = 0
  const seen = new Set()
  for (const t of (tickets || [])) {
    for (const f of (t.planned_files || [])) {
      if (seen.has(f)) continue
      seen.add(f); fileCount++
      if (Object.prototype.hasOwnProperty.call(bytesMap, f) && Number.isFinite(bytesMap[f])) {
        totalBytes += Math.max(0, bytesMap[f])
      } else { totalBytes += F.FALLBACK_FILE_BYTES; usedFallback = true }
    }
  }
  const ticketCount = Array.isArray(tickets) ? tickets.length : 0
  const predicted = Math.round((totalBytes / 4) * F.READ_FACTOR + F.FIXED_OVERHEAD + F.EXPECTED_OUTPUT_PER_TICKET * ticketCount)
  const budget = F.FIXED_OVERHEAD + F.EFFECTIVE_TASK_CONTEXT   // ADR-086 D1: calibrated basis — overhead + effective task context (NOT fraction × window)
  return {
    predicted, budget, pct: budget ? Math.round((predicted / budget) * 1000) / 10 : 0,
    over: predicted > budget, fileCount, ticketCount, totalBytes, usedFallback,
  }
}
function budgetWarnDetail(wSlug, est) {
  const fallbackNote = est.usedFallback
    ? ` File byte sizes were not all supplied via args, so a ${BUDGET_FACTORS.FALLBACK_FILE_BYTES}-byte/file fallback ` +
      `was used for ${est.fileCount} file(s) — the prediction is coarse; pass per-file bytes for precision.`
    : ''
  return `WAVE CONTEXT BUDGET (ADR-086) — wave '${wSlug}': predicted implementer consumption ~${est.predicted.toLocaleString()} ` +
    `tokens vs budget ${est.budget.toLocaleString()} (calibrated basis: FIXED_OVERHEAD ${BUDGET_FACTORS.FIXED_OVERHEAD.toLocaleString()} + ` +
    `~${BUDGET_FACTORS.EFFECTIVE_TASK_CONTEXT.toLocaleString()} effective task context — ADR-086 D1/D3, telemetry-calibrated) = ` +
    `${est.pct}% of budget. This candidate wave (${est.ticketCount} ticket(s), ${est.fileCount} planned file(s)) is predicted ` +
    `to EXCEED the budget AT PLANNING TIME. ADR-086: PROPOSE the split at the dependency seam (the slicer cut), or the ` +
    `operator may knowingly accept the over-budget wave (a recoverable, logged bet — per-ticket commits + thin manifest).${fallbackNote}`
}

// ---- schemas -------------------------------------------------------------
// ADR-062 §4 / ADR-063 §D6 — has_ui (boolean) lives on both the cto-advisor and architect-review (PRE)
// return shapes. Either agent can answer; the ui-spec dispatch fires when EITHER returns true (or the
// operator passes `wantUi:true`). Default false → skip ui-spec entirely. This retires the v1 unconditional
// ui-spec dispatch that paid the "say so in one line if no UI" tax on no-UI work.
const CTO_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['verdict', 'report', 'has_ui'],
  properties: {
    verdict: { type: 'string' },                 // GO | SIMPLIFY | DEFER | NO-GO (folded, not surfaced)
    report: { type: 'string' },                  // the full findings markdown (persisted to findings/)
    has_ui: { type: 'boolean' },                 // true if this epic/wave introduces or materially modifies a UI surface
    interrupt: { type: 'boolean' },              // true ONLY for a genuine ADR-018 crit-1/2/3/5 blocker
    interruptReason: { type: 'string' },
  },
}
// architect-review (PRE) — has_ui is REQUIRED; either cto or architect can answer for the ui-spec gate.
const ARCH_PRE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['report', 'has_ui'],
  properties: {
    report: { type: 'string' },
    has_ui: { type: 'boolean' },                 // true if this epic/wave introduces or materially modifies a UI surface
    interrupt: { type: 'boolean' }, interruptReason: { type: 'string' },
  },
}
// generic advisor (ui-spec and the per-wave architect inside Phase W; has_ui not required here).
const ADVISOR_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['report'],
  properties: { report: { type: 'string' }, interrupt: { type: 'boolean' }, interruptReason: { type: 'string' } },
}
const AUTHOR_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['markdown'],
  properties: {
    markdown: { type: 'string' },                // the FULL roadmap.md (E) / <wave>.md (W) content
    promptsMarkdown: { type: 'string' },         // Phase W only: the -prompts.md content
    waves: {                                     // Phase E author only: the fan-out work-list
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['slug', 'skeleton'],
        properties: {
          slug: { type: 'string' },              // kebab wave-slug (e.g. wave-1-foo) — drives Phase W
          skeleton: { type: 'string' },          // that wave's fat skeleton text (the Phase W intent)
        },
      },
    },
  },
}
const SPEC_SCHEMA = {                             // pm-spec authors the buildable spec BEFORE slicing
  type: 'object', additionalProperties: false,
  required: ['markdown'],
  properties: { markdown: { type: 'string' } },  // the spec narrative + AC-NNN acceptance atoms
}
const TICKETS_SCHEMA = {                          // spec-decomposer output (the doctrine-aware slice)
  type: 'object', additionalProperties: false,
  required: ['tickets'],
  properties: {
    tickets: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['key', 'description', 'planned_files', 'wave_slug'],
        properties: {
          key: { type: 'string' },               // ^[A-Z][A-Z0-9]*-[A-Z0-9]+$ (single hyphen)
          description: { type: 'string' },
          depends_on: { type: 'array', items: { type: 'string' } },     // KEYS, direct deps only
          planned_files: { type: 'array', items: { type: 'string' } },  // non-empty
          acceptance: { type: 'array', items: { type: 'string' } },     // AC-NNN atom IDs (ADR-044)
          gates: { type: 'array', items: { type: 'string' } },
          coupling_hint: { type: 'string' },      // 'high' only for genuine co-edit (ADR-048; cross-wave only under ADR-062)
          manual_review_required: { type: 'boolean' },
          // ADR-062 §1 / ADR-063 §D5 — every ticket carries the wave it belongs to. The epic-level slicer
          // emits a FLAT tickets[]; the per-wave render groups by wave_slug. Within-wave shared
          // planned_files is correct (one sequential writer); ADR-048's disjoint-planned_files contract is
          // a CROSS-WAVE rule only under ADR-062.
          wave_slug: { type: 'string' },         // the wave (kebab slug) this ticket belongs to
        },
      },
    },
  },
}
const QA_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['disposition', 'report'],
  properties: {
    disposition: { type: 'string', enum: ['LOCK', 'CONTINUE'] },
    tunings: { type: 'array', items: { type: 'string' } },
    report: { type: 'string' },                  // the recommended-reply markdown (persisted)
    verified: { type: 'boolean' },               // did verify-by-view hold?
  },
}
// PEC-T13: examiner fold-in verdict over the self-qa'd draft (Fable seat, ADR-088/095/099 — NOT re-authored).
const EXAMINE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['verdict', 'findings'],
  properties: {
    verdict: { type: 'string', enum: ['SOUND', 'FOLD-IN-REQUIRED', 'RETHINK'] },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false, required: ['id', 'prescription'],
        properties: { id: { type: 'string' }, severity: { type: 'string' }, prescription: { type: 'string' } },
      },
    },
    summary: { type: 'string' },
  },
}
const KEY_RE = /^[A-Z][A-Z0-9]*-[A-Z0-9]+$/      // ticket-key shape (single hyphen; matches the # Wave: schema)

// Deterministic '# Wave:' schema renderer. The schema is MACHINE-PARSED by wave-manifest.py, so it
// MUST be emitted by code in the EXACT parser format — never hand-formatted by an LLM. The binding
// spec-decomposer tickets[] carry every field. Parser contract (wave-manifest.py parse_wave_plan):
// plain '- field: value' labels (a '- **field:**' bold label does NOT match), list fields as
// '[inline, list]' literals (sub-bullets do NOT parse), and '- description: |' YAML literal block
// with an indented body (a fenced ``` block does NOT parse). An LLM render previously emitted the
// bold/sub-bullet/fenced variant, which the parser silently read as empty planned_files+description.
// See docs/step-6-done/deferrals/DONE-2026-06-07-roadmap-render-vs-wave-manifest-parser-format-mismatch.md.
// ADR-013 manual_review_required:false carve-out — a MECHANICAL path filter (docs/tests/config/
// fixtures only), mirrored from wave-manifest.py `_matches_manual_review_carve_out`. manual_review_required
// is DERIVED, not trusted from the LLM slice: validate() rejects `false` when any planned_file is a
// non-carve-out (source/rules/ADR/skill) path, so we force `true` unless EVERY file is carve-out.
const _CARVE_OUT_GLOBS = [
  'docs/*', 'docs/**/*', '*.md', '*.mdx', '*.txt', '*.adoc', '**/*.md', '**/*.mdx', '**/*.txt', '**/*.adoc',
  '**/*test*.ts', '**/*test*.tsx', '**/*test*.js', '**/*test*.jsx', '**/*test*.py', '**/*test*.go', '**/*test*.rs',
  '**/__tests__/*', '**/__tests__/**/*', 'tests/*', 'tests/**/*', '**/tests/*', '**/tests/**/*',
  '**/*.json', '**/*.yml', '**/*.yaml', '**/*.toml', '*.json', '*.yml', '*.yaml', '*.toml',
  '.gitignore', '.gitattributes', '**/.prettierrc*', '**/.eslintrc*', '.prettierrc*', '.eslintrc*',
  '**/tsconfig*.json', 'tsconfig*.json', '**/*.config.ts', '**/*.config.js', '**/*.config.mjs',
  '**/fixtures/*', '**/fixtures/**/*', '**/__fixtures__/*', '**/__fixtures__/**/*',
].map(p => new RegExp('^(?:' + p.split('').map(c => c === '*' ? '.*' : c === '?' ? '.' : c.replace(/[.+^${}()|[\]\\]/g, '\\$&')).join('') + ')$', 's'))
const _isCarveOut = (f) => typeof f === 'string' && _CARVE_OUT_GLOBS.some(re => re.test(f))

// Deterministic UI-surface floor (ADR-104) — the roadmap.js twin of orchestrated.js's hasUiSurface.
// DUPLICATED inline (NOT imported): the Workflow runtime forbids cross-file imports and engines are
// self-contained (ADR-039 contract 2), exactly as the wave context-budget estimator is duplicated
// between the two engines. The bodies of the classifier family below
// (normalizePlannedPath / isUiSurfacePath / hasUiSurface) are kept BYTE-IDENTICAL to orchestrated.js
// (the canonical source) — `core/scripts/test-classifier-drift.sh` goes RED if any copy drifts (SHR3-T2).
// (Previously this file carried a divergent `_uiNormalize` helper; canonicalized onto normalizePlannedPath.)
// --- classifier-family canonical block (keep byte-identical to orchestrated.js) ---
function normalizePlannedPath(p) {
  if (typeof p !== 'string' || !p) return { norm: '', suspicious: true }
  const absolute = p.startsWith('/')
  const parts = []
  let suspicious = absolute
  for (const seg of p.split('/')) {
    if (seg === '' || seg === '.') continue
    if (seg === '..') { suspicious = true; if (parts.length > 0) parts.pop(); continue }
    parts.push(seg)
  }
  return { norm: parts.join('/'), suspicious }
}
function isUiSurfacePath(p) {
  const { norm, suspicious } = normalizePlannedPath(p)
  if (suspicious || !norm) return false
  if (/\.(tsx|jsx|vue|svelte|css|scss)$/i.test(norm)) return true        // visual file extensions
  // Case-insensitive segment match (SA-INFO-1): mirrors the case-insensitive extension test so a
  // PascalCase UI dir (e.g. `Components/`) still flags — under-detection here = a silently-skipped gate.
  return norm.split('/').some(seg => ['components', 'app', 'pages', 'ui'].includes(seg.toLowerCase()))
}
function hasUiSurface(tickets) {
  for (const t of (Array.isArray(tickets) ? tickets : [])) {
    const pf = t && t.planned_files
    if (Array.isArray(pf)) for (const f of pf) if (isUiSurfacePath(f)) return true
  }
  return false
}
// --- end classifier-family canonical block ---

// advisorHasUi: the per-wave advisor/operator UI judgment (Phase W passes ctoUi||archUi||wantUiOp; Phase E
// fan-out has only an epic-level flag — too coarse to stamp per-wave — so it relies on the deterministic
// per-wave floor and passes false). Resolved has_ui = advisorHasUi OR the deterministic planned_files floor.
function renderWaveSchema(wSlug, tickets, advisorHasUi = false) {
  const hasUi = !!advisorHasUi || hasUiSurface(tickets)   // ADR-104: deterministic floor OR advisor signal
  const listLit = (arr) => '[' + (Array.isArray(arr) ? arr : []).join(', ') + ']'
  // ADR-113 sibling (from-dogfood-v2-round-2): a per-wave '# Wave:' file is validated STANDALONE by
  // wave-manifest.py, so it must carry IN-WAVE depends_on ONLY. Cross-wave ordering lives in the build
  // order (the roadmap wave sequence; the in-place sequential build, ADR-062) + the validated flat epic
  // graph — never in a per-wave ticket's depends_on (which would read as an unknown-ticket + false cycle).
  const inWaveKeys = new Set((Array.isArray(tickets) ? tickets : []).map(t => t.key))
  const inWaveDeps = (deps) => (Array.isArray(deps) ? deps : []).filter(d => inWaveKeys.has(d))
  const titleOf = (t) => {
    const first = String(t.description || '').split('\n').map(s => s.trim()).filter(Boolean)[0] || t.key
    return first.length > 80 ? first.slice(0, 77).replace(/\s+\S*$/, '') + '…' : first
  }
  const block = (t) => {
    const pf = Array.isArray(t.planned_files) ? t.planned_files : []
    const declared = (typeof t.manual_review_required === 'boolean') ? t.manual_review_required : true
    // Respect declared value ONLY when every file is carve-out; otherwise force true (validator C7).
    const mrr = pf.length && pf.every(_isCarveOut) ? declared : true
    // Indent every description line 4 spaces: keeps the YAML literal block intact AND neutralizes any
    // embedded markdown headers (a col-0 '### ' / '## ' would otherwise terminate the description).
    const body = String(t.description || '').replace(/\r/g, '').split('\n').map(l => '    ' + l).join('\n')
    return [
      `### ${t.key}: ${titleOf(t)}`,
      `- depends_on: ${listLit(inWaveDeps(t.depends_on))}`,
      `- planned_files: ${listLit(t.planned_files)}`,
      // ADR-103 W1 / ADR-086 D4: render the AC-NNN atom chain INTO the persisted '# Wave:' artifact.
      // The ticket carries acceptance[] in memory (TICKETS_SCHEMA above) but it was never emitted here, so
      // the atom chain was severed at render — wave-manifest.py parsed no acceptance, the graduated-spec
      // ingest defaulted it to [], and AC-COVERAGE fired a phantom GAP on 100% of authored waves. Carrying
      // the atoms as data (not re-derivation) is the continuity property: downstream reads intent, never re-mints it.
      `- acceptance: ${listLit(t.acceptance)}`,
      `- gate_recommendations: ${listLit(t.gates)}`,
      `- manual_review_required: ${mrr}`,
      `- description: |`,
      body,
      ``,
    ].join('\n')
  }
  // **Has UI:** carries the resolved has_ui across the planning→build handoff (ADR-104). wave-manifest.py
  // parses it; the /orchestrated dispatch passes it as `hasUi` so the build's ui-spec/ui-review fire without
  // the operator re-deriving it. Absent header parses as false downstream (legacy-safe).
  return [`# Wave: ${wSlug}`, `**Protocol version:** 3`, `**Has UI:** ${hasUi}`, ``, `## Tickets`, ``, ...tickets.map(block)].join('\n')
}

// pm-spec authors ONLY the per-ticket build prose; the schema is rendered deterministically above.
const PROMPTS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['promptsMarkdown'],
  properties: { promptsMarkdown: { type: 'string' } },
}

// ===========================================================================
// INTENT-CAPTURE (ADR-065, amended 2026-06-13) — SELF-CONTAINED, INLINE.
// The native Workflow runtime forbids ALL cross-file module loads: a top-level static import is rejected
// by the validator (meta must be the FIRST statement), and the dynamic form is unavailable at runtime
// ("not available in workflow scripts"). So the shared sibling-module design is runtime-incompatible. The
// decision logic now lives HERE, inline in roadmap.js (the only consumer; orchestrated.js dropped
// intent-capture entirely — it almost always carries a task/spec and short-circuited anyway).
//
// intentSource enum (ADR-065 §3 — binding):
//   'capture'    -> dispatch pm-spec (capture-from-jam role) to read the jam and ground intent by-view.
//   'curated'    -> short-circuit: the verbatim providedIntent flows through (zero agent dispatch).
//   'jam-direct' -> short-circuit: same as curated (ADR-051 §9 jam->build-direct).
// FAIL-SAFE: an unrecognized intentSource THROWS (no silent default — a typo'd source must not skip capture).
// NO surface / NO throw on empty (ADR-039 contract 3) — the engine maps empty onto its OWN crit-1 interrupt.
// CR-002: the jam path resolves from `jamSlug` when provided, else `epicSlug` — so the skill's "name a
// different jam" affordance (SKILL.md jamSlug arg) reaches the right docs/step-2-planning/jam-<slug>/.
// ===========================================================================
const CAPTURE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['markdown'],
  properties: { markdown: { type: 'string' } },
}
const VALID_INTENT_SOURCES = ['capture', 'curated', 'jam-direct']
async function runIntentCapture({ providedIntent = '', intentSource = 'capture' } = {}) {
  // Fail-safe — an unrecognized source must NOT silently default.
  if (!VALID_INTENT_SOURCES.includes(intentSource)) {
    throw new Error(`intent-capture: unrecognized intentSource '${intentSource}' (expected one of ${VALID_INTENT_SOURCES.join('|')})`)
  }
  // Escape hatches — zero agent dispatch; the verbatim provided intent flows through.
  if (intentSource === 'curated' || intentSource === 'jam-direct') {
    log(`intent-capture: short-circuit (intentSource='${intentSource}') — no capture dispatch`)
    return { markdown: providedIntent || '', captured: false }
  }
  // intentSource === 'capture' — dispatch pm-spec to read+ground the jam.
  phase('intent-capture')
  // CR-002: resolve the LIVE jam workspace path from jamSlug (operator named a different jam) else epicSlug.
  const slug = _a.jamSlug || epicSlug
  const jamPath = `docs/step-2-planning/jam-${slug}/`
  const seed = (providedIntent && providedIntent.trim())
    ? `\n\nA seed intent/task was also supplied — reconcile it with the jam:\n${providedIntent}`
    : ''
  const cap = await agentRetry(
    `You are pm-spec in your capture-from-jam role (core/agents/pm-spec.md). Capture and ground the epic intent ` +
    `(repo ${repoRoot}). Read ${jamPath}README.md (fallback ${jamPath}index.md) + every ${jamPath}source/*.md; ` +
    `GROUND load-bearing claims by view (ADR-051 §8 — correct any code-blind claim). Return \`markdown\` = the ` +
    `converged, feasibility-grounded epic intent (do NOT slice into tickets; this captures intent only). ` +
    // ADR-113 D2 — pass-by-path handoff: write the grounded intent to the run folder so downstream Phase-E
    // dispatches read it by path instead of re-inlining it (the run-folder agent-handoff, ADR-039 #2 refinement).
    `REQUIRED: in addition to returning \`markdown\`, WRITE the SAME grounded intent to \`${runDir}/intent.md\` ` +
    `using your Write tool (write ONLY under ${runDir} — never docs/step-3-specs/**); peer agents read it from there.${seed}`,
    { label: 'intent-capture', phase: 'intent-capture', agentType: 'pm-spec', schema: CAPTURE_SCHEMA }
  )
  const markdown = cap ? (cap.markdown || '') : ''
  // No surface / no throw on empty (ADR-039 contract 3) — the engine maps empty onto its crit-1 path.
  return { markdown, captured: true }
}

const findings = {}                              // {name: markdown} -> persist writes findings/{name}.md
const criterionFindings = []                     // ADR-018 interrupts only (top-level aggregate)
const warnFindings = []                          // ADR-086 D4: informational WARNs (budget/atom-chain) — surface, never halt
function warn(gate, id, detail) {
  warnFindings.push({ gate, id, kind: 'WARN', severity: 'low', criterion_match: 'none', recommended_disposition: 'DISMISS', detail })
  log(`WARN [${gate}/${id}]: ${String(detail).slice(0, 200)}`)
}

function interruptFinding(gate, reason) {
  criterionFindings.push({
    gate, id: gate.toUpperCase(), severity: 'critical',
    criterion_match: 'crit-1', recommended_disposition: 'ESCALATE',
    detail: `roadmap ${gate} raised an ADR-018 interrupt: ${String(reason || '').slice(0, 500)}`,
  })
}

// ADR-113 D1 — bounded dispatch retry. A FRESH re-dispatch (distinct from the harness's own internal
// retries) on a null/undefined return, up to `tries` total. A transient socket death (the run-2 forfeit
// at :800) recovers in-run instead of forfeiting ~190k tokens of completed upstream work. tries=2 (one
// retry) is bounded so a DETERMINISTIC failure does not amplify cost unboundedly — the existing
// null-guards still surface after exhaustion (this never swallows a terminal failure, it just retries once).
async function agentRetry(prompt, opts, tries = 2) {
  let r = null
  for (let i = 0; i < tries; i++) {
    r = await agent(prompt, opts)
    if (r !== null && r !== undefined) return r
    if (i < tries - 1) log(`${(opts && opts.label) || 'agent'}: null result (attempt ${i + 1}/${tries}) — re-dispatching`)
  }
  return r
}

// Validate the tickets graph (mirrors orchestrated.js): key shape, uniqueness, orphan deps, cycle.
// Returns an array of human-readable errors ([] = valid).
function validateTicketGraph(tickets) {
  const errs = []
  const seen = new Set()
  const keys = new Set(tickets.map(t => t.key))
  for (const t of tickets) {
    if (!KEY_RE.test(t.key || '')) errs.push(`invalid ticket key shape '${t.key}'`)
    if (seen.has(t.key)) errs.push(`duplicate ticket key '${t.key}'`)
    seen.add(t.key)
    if (!Array.isArray(t.planned_files) || t.planned_files.length === 0) errs.push(`ticket '${t.key}' has empty planned_files`)
    for (const d of (t.depends_on || [])) if (!keys.has(d)) errs.push(`ticket '${t.key}' depends_on unknown key '${d}'`)
  }
  const byK = Object.fromEntries(tickets.map(t => [t.key, t]))
  const colour = {}
  for (const t of tickets) colour[t.key] = 0   // 0=white 1=grey 2=black
  function dfs(k) {
    if (!byK[k]) return false
    colour[k] = 1
    for (const d of (byK[k].depends_on || [])) {
      if (!byK[d]) continue
      if (colour[d] === 1) return true                       // back-edge => cycle
      if (colour[d] === 0 && dfs(d)) return true
    }
    colour[k] = 2
    return false
  }
  for (const t of tickets) if (colour[t.key] === 0 && dfs(t.key)) { errs.push(`dependency cycle through '${t.key}'`); break }
  return errs
}

// WAVE-PARTITION-AWARE validation (PEC-T5 / ADR-112). validateTicketGraph above treats the
// flat epic graph as ONE undifferentiated acyclic graph — it cannot tell an intra-wave sequencing edge
// (depends_on within a wave_slug group: a hint for the one in-wave writer) from an inter-wave edge (a
// depends_on crossing a wave_slug boundary: the parallel-merge contract). The default-straight build
// (orchestrated.js) front-loads ALL waves and inherits exactly this seam, so it must be validated here.
// Two assertions, both fail CLOSED (the caller pushes any error into the crit-1 DECOMP-GRAPH surface):
//   (a) wave ORDERING: the inter-wave edges form an acyclic wave DAG (the depended-on wave builds before
//       the dependent wave; an inverted/cyclic wave ordering is rejected).
//   (b) across-wave DISJOINT-SINK (ADR-048 amended by ADR-062): two PARALLEL cross-wave tickets (neither
//       transitively depends on the other) MUST NOT share a planned_files sink without an edge between
//       them — an unedged shared cross-wave sink conflicts at the wave merge.
// PURE graph analysis — no agent, no FS. Assumes the ticket-level graph is already acyclic (the caller
// runs validateTicketGraph first); a defensive in-progress guard keeps the reachability walk safe anyway.
function validateWavePartition(tickets) {
  const errs = []
  const list = Array.isArray(tickets) ? tickets : []
  const byK = Object.fromEntries(list.map(t => [t.key, t]))
  const waveOf = k => byK[k] && byK[k].wave_slug
  // (a) inter-wave edge -> wave DAG; cycle = inverted/cyclic wave ordering.
  const waveEdges = new Map()                       // dependentWave -> Set(dependedWave)
  const allWaves = new Set(list.map(t => t.wave_slug).filter(Boolean))
  for (const t of list) {
    for (const d of (t.depends_on || [])) {
      const dw = waveOf(d), tw = t.wave_slug
      if (dw && tw && dw !== tw) {
        if (!waveEdges.has(tw)) waveEdges.set(tw, new Set())
        waveEdges.get(tw).add(dw)
      }
    }
  }
  const wc = {}                                     // 0 white / 1 grey / 2 black
  for (const w of allWaves) wc[w] = 0
  function wdfs(w) {
    wc[w] = 1
    for (const dw of (waveEdges.get(w) || [])) {
      if (wc[dw] === 1) return true                 // back-edge => wave-ordering cycle
      if (wc[dw] === 0 && wdfs(dw)) return true
    }
    wc[w] = 2
    return false
  }
  for (const w of allWaves) if (wc[w] === 0 && wdfs(w)) { errs.push(`inter-wave dependency cycle through wave '${w}' (inverted/cyclic wave ordering)`); break }
  // (b) across-wave disjoint-sink. Transitive ticket-level reachability for the parallel test.
  const reach = {}
  function computeReach(k, visiting) {
    if (reach[k]) return reach[k]
    if (visiting.has(k)) return new Set()           // cycle guard (graph already validated acyclic upstream)
    visiting.add(k)
    const s = new Set()
    for (const d of ((byK[k] && byK[k].depends_on) || [])) {
      if (!byK[d]) continue
      s.add(d)
      for (const x of computeReach(d, visiting)) s.add(x)
    }
    visiting.delete(k)
    reach[k] = s
    return s
  }
  for (const t of list) computeReach(t.key, new Set())
  const dependsOn = (a, b) => !!(reach[a] && reach[a].has(b))
  const parallel = (a, b) => !dependsOn(a, b) && !dependsOn(b, a)
  for (let i = 0; i < list.length; i++) {
    for (let j = i + 1; j < list.length; j++) {
      const a = list[i], b = list[j]
      if (!a.wave_slug || !b.wave_slug || a.wave_slug === b.wave_slug) continue   // cross-wave pairs only
      if (!parallel(a.key, b.key)) continue                                       // an edge serializes them => OK
      const af = new Set(a.planned_files || [])
      const shared = (b.planned_files || []).filter(f => af.has(f))
      if (shared.length) errs.push(
        `parallel cross-wave tickets '${a.key}' (${a.wave_slug}) and '${b.key}' (${b.wave_slug}) share ` +
        `planned_files sink(s) [${shared.join(', ')}] with no depends_on edge between them ` +
        `(across-wave disjoint-sink rule, ADR-048/ADR-062)`)
    }
  }
  return errs
}

// AUTO-SERIALIZE cross-wave shared-sink collisions (ADR-121). Runs in runPhaseE AFTER validateTicketGraph
// (acyclic ticket graph assured) and BEFORE validateWavePartition. For the default-straight sequential
// in-place build (ADR-062/112), two waves sharing a planned_files sink are NOT a parallel-write hazard —
// they just need a deterministic ORDER. Rather than hard-fail the (already-spent) epic decompose on such a
// collision, derive the serialization edge: the LATER-built wave's colliding ticket depends_on the
// EARLIER-built wave's colliding ticket. Build order = first-appearance of wave_slug in the flat tickets[]
// (the SAME order runPhaseE groups waves by). An edge is added ONLY when neither ticket already reaches the
// other (checked via FRESH per-pair reachability that reflects edges added earlier in this loop — see
// `reaches`), so `earlier` does not reach `later` and adding later->earlier CANNOT close a cycle (cycle-safe
// by construction, not by a downstream net — CR-001). renderWaveSchema strips cross-wave depends_on from the
// per-wave files (ADR-113), so these edges live only in the flat epic graph + the build order. A genuine
// AUTHORED inter-wave CYCLE (e.g. a pre-existing inverted inter-wave edge) is left untouched and still
// hard-fails via validateWavePartition case (a). DETERMINISTIC: mutates tickets' depends_on and RETURNS the
// added edges [{later, earlier, sinks, lw, ew}]; the caller emits the WARNs (D3).
function deriveCrossWaveSerialization(tickets) {
  const list = Array.isArray(tickets) ? tickets : []
  const added = []
  // wave build order = first-appearance of each wave_slug in the flat list (matches runPhaseE waveOrder).
  const waveIdx = new Map()
  for (const t of list) if (t.wave_slug && !waveIdx.has(t.wave_slug)) waveIdx.set(t.wave_slug, waveIdx.size)
  const byK = Object.fromEntries(list.map(t => [t.key, t]))
  // FRESH transitive reachability over the LIVE depends_on graph — recomputed per query so it reflects edges
  // added earlier in THIS loop (no stale cache). `reaches(from,to)` = does `from` transitively depend on `to`?
  // Small graphs (roadmaps carry tens of tickets), so per-query DFS is cheap. This is the cycle-safety
  // invariant (CR-001/ADR-121): an edge later->earlier is added ONLY when neither already reaches the other,
  // so `earlier` does not reach `later`, so adding later->earlier CANNOT close a cycle — verified by
  // construction, not by a downstream net.
  const reaches = (from, to) => {
    const seen = new Set()
    const stack = [from]
    while (stack.length) {
      const k = stack.pop()
      for (const d of ((byK[k] && byK[k].depends_on) || [])) {
        if (d === to) return true
        if (!seen.has(d) && byK[d]) { seen.add(d); stack.push(d) }
      }
    }
    return false
  }
  for (let i = 0; i < list.length; i++) {
    for (let j = i + 1; j < list.length; j++) {
      const a = list[i], b = list[j]
      if (!a.wave_slug || !b.wave_slug || a.wave_slug === b.wave_slug) continue   // cross-wave pairs only
      if (reaches(a.key, b.key) || reaches(b.key, a.key)) continue                // already ordered => OK
      const af = new Set(a.planned_files || [])
      const shared = (b.planned_files || []).filter(f => af.has(f))
      if (!shared.length) continue
      // serialize: the later-built wave's ticket depends_on the earlier-built wave's ticket. Neither reaches
      // the other (checked FRESH above), so this edge cannot create a cycle.
      const [earlier, later] = (waveIdx.get(a.wave_slug) <= waveIdx.get(b.wave_slug)) ? [a, b] : [b, a]
      if (!Array.isArray(later.depends_on)) later.depends_on = []
      if (!later.depends_on.includes(earlier.key)) {
        later.depends_on.push(earlier.key)
        added.push({ later: later.key, earlier: earlier.key, sinks: shared, lw: later.wave_slug, ew: earlier.wave_slug })
      }
    }
  }
  return added
}

// ===========================================================================
// runPhaseW — the reusable Phase W funnel (one wave -> spec + prompts + tickets).
// cto -> architect -> [ui-spec] -> pm-spec(spec) -> spec-decomposer(slice) -> graph-validate -> pm-spec(render).
// The slice is owned by spec-decomposer (the ONE slicer — ADR-044/047/048), mirroring orchestrated.js's
// planning portion; pm-spec then RENDERS the parseable '# Wave:' schema from that binding slice (no re-slice).
// LOCAL findings/criterionFindings so the Phase E fan-out can run it per wave without cross-contamination.
//   wSlug       : kebab wave slug
//   wSkeleton   : the wave's fat skeleton (Phase W intent)
//   priorSpecs  : [{slug, waveSpecMarkdown}] already-planned earlier waves (sequential build-on context)
//   attendedW   : true => return the round after self-QA WITHOUT finalizing (standalone Phase W only)
//   phasePrefix : progress-group prefix (fan-out passes '<slug>:' so waves don't merge in /workflows)
// Returns: { waveSlug, waveSpecMarkdown, wavePromptsMarkdown, tickets, findings, criterionFindings,
//            selfQA, surfaceRequired, surfaceType }
// ===========================================================================
async function runPhaseW(wSlug, wSkeleton, priorSpecs = [], attendedW = false, phasePrefix = '') {
  const wf = {}                                  // local findings for this wave
  const wcf = []                                 // local criterionFindings for this wave
  const wwf = []                                 // local WARN findings for this wave (ADR-086 D4)
  const wWarn = (gate, id, detail) => {
    wwf.push({ gate: `${phasePrefix}${gate}`, id, kind: 'WARN', severity: 'low', criterion_match: 'none', recommended_disposition: 'DISMISS', detail })
    log(`WARN [${phasePrefix}${gate}/${id}]: ${String(detail).slice(0, 200)}`)
  }
  const lbl = (name) => phasePrefix ? `${name}:${wSlug}` : name
  const ph = (name) => phase(`${phasePrefix}${name}`)
  const wInterrupt = (gate, reason) => wcf.push({
    gate: `${phasePrefix}${gate}`, id: gate.toUpperCase(), severity: 'critical',
    criterion_match: 'crit-1', recommended_disposition: 'ESCALATE',
    detail: `roadmap ${gate} (wave ${wSlug}) raised an ADR-018 interrupt: ${String(reason || '').slice(0, 500)}`,
  })
  const ret = (extra) => ({
    waveSlug: wSlug, waveSpecMarkdown: '', wavePromptsMarkdown: '', tickets: [], selfQA: null,
    findings: wf, criterionFindings: wcf, warnFindings: wwf,
    surfaceRequired: wcf.length > 0, surfaceType: wcf.length > 0 ? 'validate-fail' : null,
    ...extra,
  })
  // ADR-083 D4 — prior-wave digest. Waves after the first carry a DIGEST of each prior wave (slug +
  // ticket keys + first 300 chars of the wave spec), not the full prior-wave spec text — the full text
  // is an N× multiplier across an epic and the build-on context only needs the shape (what tickets exist,
  // what they deliver). Ticket keys are read from the '### KEY: title' headers renderWaveSchema emits.
  const priorWaveDigest = (p) => {
    const md = String(p.waveSpecMarkdown || '')
    const keys = []
    for (const line of md.split('\n')) {
      const m = line.match(/^###\s+([A-Z][A-Z0-9]*-[A-Z0-9]+):/)
      if (m) keys.push(m[1])
    }
    const keyLine = keys.length ? keys.join(', ') : '(no ticket keys parsed)'
    return `### ${p.slug} — tickets: ${keyLine}\n${md.slice(0, 300)}${md.length > 300 ? ' […digested]' : ''}`
  }
  const priorCtx = priorSpecs.length
    ? `\n\nPRIOR WAVES (already planned this epic — this wave BUILDS ON TOP of them; do NOT duplicate their tickets, ` +
      `depend on their delivered files/outputs instead). Digest only (slug + ticket keys + spec excerpt):\n` +
      priorSpecs.map(priorWaveDigest).join('\n\n')
    : ''

  ph('decompose')
  const ctoW = await agentRetry(
    `Strategic/feasibility gate for roadmap Phase W on wave '${wSlug}' (repo ${repoRoot}). The wave's fat skeleton ` +
    `is below. Catch code-blind assumptions; a SIMPLIFY folds, it does not block. interrupt=true only for ADR-018 ` +
    `crit-1/2/3/5. Set has_ui=true if this wave introduces or materially modifies a UI surface (REQUIRED — drives ` +
    `the conditional ui-spec dispatch, ADR-062 §4 / ADR-063 §D6).\n\nWAVE SKELETON:\n${wSkeleton}${priorCtx}`,
    { label: lbl('cto-advisor'), phase: `${phasePrefix}decompose`, agentType: 'cto-advisor', schema: CTO_SCHEMA }
  )
  wf['cto-advisor'] = ctoW ? ctoW.report : '(cto-advisor died)'
  if (ctoW && ctoW.interrupt) wInterrupt('decompose', ctoW.interruptReason)

  const architect = await agentRetry(
    `Architectural gate for wave '${wSlug}' (repo ${repoRoot}): ticket decomposition, ADR territory, carryover folds. ` +
    `Advisory. interrupt=true only for ADR-018 crit-1/2/3/5. Set has_ui=true if this wave introduces or materially ` +
    `modifies a UI surface (REQUIRED).\n\nWAVE SKELETON:\n${wSkeleton}\n\nCTO:\n${wf['cto-advisor']}${priorCtx}`,
    { label: lbl('architect-review'), phase: `${phasePrefix}decompose`, agentType: 'architect-review', schema: ARCH_PRE_SCHEMA }
  )
  wf['architect-review'] = architect ? architect.report : '(architect-review died)'
  if (architect && architect.interrupt) wInterrupt('architect', architect.interruptReason)

  // ui-spec is conditional on has_ui from cto/architect (or `wantUi:true`). Default false → skip (ADR-062 §4).
  const ctoUi = !!(ctoW && ctoW.has_ui)
  const archUi = !!(architect && architect.has_ui)
  const wantUiOp = _a.wantUi === true
  let ui = null
  if (ctoUi || archUi || wantUiOp) {
    ui = await agentRetry(
      `UI spec for wave '${wSlug}' (repo ${repoRoot}): concrete visual requirements + error-state UX for any NEW UI ` +
      `surface. Advisory.\n\nWAVE SKELETON:\n${wSkeleton}`,
      { label: lbl('ui-spec'), phase: `${phasePrefix}decompose`, agentType: 'ui-spec', schema: ADVISOR_SCHEMA }
    )
    wf['ui-spec'] = ui ? ui.report : '(ui-spec died)'
  } else {
    wf['ui-spec'] = `(ui-spec skipped — cto.has_ui=${ctoUi}, architect.has_ui=${archUi}, wantUi=${wantUiOp})`
    log(`ui-spec: skipped for wave '${wSlug}' (no UI surface)`)
  }

  // --- pm-spec authors the buildable SPEC (mirrors orchestrated's 'spec' phase — NOT the ticket slice) ---
  ph('spec')
  const specDraft = await agentRetry(
    `You are pm-spec. Author the buildable SPEC for wave '${wSlug}' (repo ${repoRoot}) — a narrative spec with ` +
    `numbered AC-NNN acceptance atoms. Do NOT slice into tickets yourself; spec-decomposer owns the slice next. ` +
    `Return \`markdown\` = the spec. ` +
    // ADR-113 D2 — pass-by-path handoff: write the wave spec to the run folder so downstream dispatches
    // (spec-decomposer, render, finalize) read it by path instead of re-inlining it. The wave intent is the
    // skeleton (passed inline below) — no producing agent writes it, so intent stays inline in Phase W.
    `REQUIRED: in addition to returning \`markdown\`, WRITE the SAME spec to \`${runDir}/spec.md\` using your Write ` +
    `tool (write ONLY under ${runDir} — never docs/step-3-specs/**); peer agents read the binding spec from there.\n\n` +
    `WAVE SKELETON:\n${wSkeleton}\n\nARCHITECT:\n${wf['architect-review']}\n\nUI-SPEC:\n${wf['ui-spec']}${priorCtx}`,
    { label: lbl('pm-spec'), phase: `${phasePrefix}spec`, agentType: 'pm-spec', schema: SPEC_SCHEMA }
  )
  const specText = specDraft ? (specDraft.markdown || '') : ''
  wf['pm-spec'] = specText || '(pm-spec returned empty spec)'
  if (!specText.trim()) { wInterrupt('spec', 'pm-spec returned empty wave spec'); return ret({ surfaceRequired: true, surfaceType: 'unknown' }) }

  // --- spec-decomposer owns the slice — the ONE slicer (ADR-044 AC-coverage + ADR-048 shared-sink) ---
  const waveKeyHint = (wSlug.split('-').map(w => w[0] || '').join('') || 'W').toUpperCase()
  ph('decompose-tickets')
  const decomp = await agentRetry(
    `spec-decomposer: decompose this wave spec into self-contained tickets for parallel implementation. Repo: ${repoRoot}.\n\n` +
    `Read the binding wave spec at \`${runDir}/spec.md\`.\n\nEach ticket: a stable key matching ^[A-Z][A-Z0-9]*-[A-Z0-9]+$ (SINGLE hyphen, e.g. ${waveKeyHint}-T1, ${waveKeyHint}-T2), ` +
    `a description, depends_on (KEYS of tickets it directly depends on; [] for a leaf), planned_files (NON-EMPTY — the ` +
    `files it creates/modifies), acceptance (the AC-NNN atom IDs from the spec this ticket claims — every AC-NNN in the ` +
    `spec must be claimed by >=1 ticket; ADR-044), gates (recommended gate agents), and manual_review_required.\n` +
    `SHARED-SINK RULE (ADR-048, load-bearing): two tickets with NO depends_on edge between them MUST NOT name the same ` +
    `file in planned_files — a shared append sink conflicts at integrate even when each ticket's content is disjoint. ` +
    `Serialize a shared sink with a depends_on edge (default) or set coupling_hint:"high" (genuine co-edit only). ` +
    `Slice per the doctrine in core/reference/ticket-slicing-doctrine.md. Return { tickets: [...] }.`,
    { label: lbl('spec-decomposer'), phase: `${phasePrefix}decompose-tickets`, agentType: 'spec-decomposer', schema: TICKETS_SCHEMA }
  )
  const tickets = (decomp && Array.isArray(decomp.tickets)) ? decomp.tickets : []
  wf['spec-decomposer'] = tickets.length
    ? tickets.map(t => `- ${t.key}: ${String(t.description || '').split('\n')[0]} [deps: ${(t.depends_on || []).join(',') || 'none'}; files: ${(t.planned_files || []).join(', ') || 'NONE'}]`).join('\n')
    : '(spec-decomposer returned no tickets)'
  if (!tickets.length) { wInterrupt('decompose-tickets', 'spec-decomposer returned no tickets'); return ret({ surfaceRequired: true, surfaceType: 'unknown' }) }

  // Graph validation up front (fail-closed to a surface on a bad graph — mirrors orchestrated.js).
  const graphErrors = validateTicketGraph(tickets)
  if (graphErrors.length) {
    for (const e of graphErrors) wcf.push({
      gate: `${phasePrefix}decompose-tickets`, id: 'DECOMP-GRAPH', severity: 'high',
      criterion_match: 'crit-1', recommended_disposition: 'ESCALATE', detail: `wave ${wSlug}: ${e}`,
    })
    return ret({ tickets, surfaceRequired: true, surfaceType: 'validate-fail' })
  }

  // --- WAVE CONTEXT-BUDGET WARN (ADR-086 D2/D4 — T4a). Estimate this candidate wave's implementer
  // consumption AT PLANNING TIME; over budget => WARN-class finding (informational; never blocks). ---
  {
    const est = estimateWaveTokens(tickets, fileBytes)
    if (est.over) wWarn('context-budget', `WAVE-BUDGET-${wSlug}`, budgetWarnDetail(wSlug, est))
    else log(`context-budget: OK — wave '${wSlug}' predicted ~${est.predicted.toLocaleString()} tokens (${est.pct}% of budget${est.usedFallback ? ', coarse' : ''})`)
  }

  // --- ATOM-CHAIN GUARD (ADR-086 / handoff T6). Warn when a ticket carries empty acceptance[] while the
  // spec mints AC-NNN atoms — the coverage check would otherwise read a phantom dropped-scope GAP. ---
  if (/\bAC-\d{3}\b/.test(specText || '')) {
    for (const t of tickets) {
      if (!Array.isArray(t.acceptance) || t.acceptance.length === 0) {
        wWarn('atom-chain', `ATOM-CHAIN-${t.key}`,
          `hand-fed ticket ${t.key} broke the atom chain — wave '${wSlug}' spec mints AC-NNN atoms but this ticket ` +
          `carries none in acceptance[]; the coverage check will read a phantom dropped-scope GAP. See the ` +
          `spec-decomposer contract (every AC-NNN claimed by >=1 ticket; ADR-044/ADR-086 T6). Warn, not block.`)
      }
    }
  }

  // --- pm-spec RENDERS the parseable '# Wave:' schema from the BINDING slice (no re-slice) ---
  ph('author')
  // The '# Wave:' schema is rendered DETERMINISTICALLY from the binding tickets[] (machine-parsed by
  // wave-manifest.py — never LLM-hand-formatted). pm-spec authors ONLY the per-ticket build prose.
  // ADR-104: Phase W has a per-wave advisor judgment — OR it with the deterministic planned_files floor.
  let wMarkdown = renderWaveSchema(wSlug, tickets, ctoUi || archUi || wantUiOp)
  if (!wMarkdown.trim() || !tickets.length) { wInterrupt('author', 'deterministic wave schema render was empty (no binding tickets)'); return ret({ tickets, surfaceRequired: true, surfaceType: 'unknown' }) }
  const wDraft = await agentRetry(
    `You are pm-spec, the integrator. Author the per-ticket BUILD PROSE (\`promptsMarkdown\`) for wave '${wSlug}'. ` +
    `The buildable '# Wave:' ticket schema is ALREADY rendered (below) — do NOT reproduce or reformat it; write the ` +
    `human-facing build guidance per ticket (context, approach, gotchas, acceptance), keyed to the EXACT ticket keys.\n\n` +
    `WAVE SCHEMA (rendered — authoritative, do not restate):\n${wMarkdown}\n\nTICKETS (binding slice):\n${JSON.stringify(tickets, null, 2)}\n\n` +
    `Read the binding wave spec at \`${runDir}/spec.md\`.\n\nARCHITECT:\n${wf['architect-review']}\n\nUI-SPEC:\n${wf['ui-spec']}`,
    { label: lbl('pm-spec-render'), phase: `${phasePrefix}author`, agentType: 'pm-spec', schema: PROMPTS_SCHEMA }
  )
  let wPrompts = wDraft ? (wDraft.promptsMarkdown || '') : ''

  ph('self-qa')
  const qaW = await agentRetry(
    `Read-only self-QA of this wave spec (repo ${repoRoot}). Re-verify by view; check the '# Wave:' schema looks ` +
    `parseable (single-hyphen keys, non-empty planned_files). Recommend LOCK/CONTINUE + tunings[].\n\nWAVE SPEC:\n${wMarkdown}`,
    { label: lbl('self-qa'), phase: `${phasePrefix}self-qa`, agentType: 'planner', schema: QA_SCHEMA }
  )
  wf['round-1-recommended-reply'] = qaW ? qaW.report : '(planner self-QA died)'

  // Attended (standalone Phase W only): return the round BEFORE finalizing; orchestrator presents the boundary.
  if (attendedW) return ret({ tickets, waveSpecMarkdown: wMarkdown, wavePromptsMarkdown: wPrompts, selfQA: qaW || null, surfaceRequired: true, surfaceType: 'roadmap-round' })

  if (qaW && qaW.disposition === 'CONTINUE' && Array.isArray(qaW.tunings) && qaW.tunings.length) {
    ph('finalize')
    // The schema is deterministic (renderWaveSchema over the binding tickets[]); tunings that would
    // re-slice/rename tickets are out of scope here (that's a spec-decomposer re-run). So finalize folds
    // planner tunings into the BUILD PROSE only; wMarkdown stays the rendered schema, guaranteed parseable.
    const finalizedW = await agentRetry(
      `Fold these planner tunings into the per-ticket build prose for wave '${wSlug}'. Return \`promptsMarkdown\` only. ` +
      `Do NOT alter ticket keys, depends_on, or planned_files (the schema is fixed and authoritative).\n\n` +
      `WAVE SCHEMA (fixed):\n${wMarkdown}\n\nCURRENT PROMPTS:\n${wPrompts}\n\nTUNINGS:\n- ${qaW.tunings.join('\n- ')}`,
      { label: lbl('finalize'), phase: `${phasePrefix}finalize`, agentType: 'pm-spec', schema: PROMPTS_SCHEMA }
    )
    if (finalizedW && finalizedW.promptsMarkdown && finalizedW.promptsMarkdown.trim()) wPrompts = finalizedW.promptsMarkdown
  }

  return ret({ tickets, waveSpecMarkdown: wMarkdown, wavePromptsMarkdown: wPrompts, selfQA: qaW || null, surfaceRequired: wcf.length > 0, surfaceType: wcf.length > 0 ? 'validate-fail' : null })
}

// ===========================================================================
// PHASE E — epic -> wave roadmap. One epic funnel (ADR-062 §4 / ADR-063 §D5):
//   research -> cto (epic) -> architect-PRE (epic) -> [ui-spec if has_ui]
//             -> pm-spec(spec over whole epic) -> spec-decomposer (flat tickets[], each carries wave_slug)
//             -> pm-spec(render) groups by wave_slug, authors per-wave <wave-slug>.md files.
//
// Retires (ADR-058 amended): the per-wave fan-out loop (the v1 `for (const w of waveList)` over runPhaseW)
// — paying cto + architect + ui-spec + pm-spec(spec) + spec-decomposer + planner ONCE PER WAVE. Three
// waves of no-UI work paid 3× ui-spec under v1; the epic funnel pays one cto, one architect, one (conditional)
// ui-spec, one pm-spec(spec), one spec-decomposer, and one pm-spec(render) for the whole epic.
// ===========================================================================
if (rmPhase === 'E') {
  // --- intent-capture (ADR-065, amended — FIRST Phase-E step) via the INLINE, self-contained helper
  // (runIntentCapture above; no cross-file import — the Workflow runtime forbids all imports). Default
  // 'capture' dispatches pm-spec to read the jam and ground intent by-view; 'curated'/'jam-direct'
  // short-circuit to the verbatim `intent`. The `intent` arg stays const; the captured result lives in a
  // NEW local `capturedIntent`. The helper owns no surface (ADR-039 contract 3) — this engine maps an
  // empty capture onto its crit-1 interrupt below.
  const cap = await runIntentCapture({ providedIntent: intent, intentSource })
  const capturedIntent = cap.markdown
  if (cap.captured) {
    findings['intent-capture'] = capturedIntent || '(intent-capture returned empty)'
    // Empty capture AND no verbatim intent fallback => ADR-018 crit-1 interrupt (mirrors the empty-spec guard).
    if (!capturedIntent.trim()) {
      interruptFinding('research', 'intent-capture returned empty markdown and no verbatim intent was supplied')
      return { track: 'roadmap', phase: 'E', epicSlug, roadmapMarkdown: '', waves: [], findings, criterionFindings, surfaceRequired: true, surfaceType: 'unknown' }
    }
  }

  phase('research')
  const research = (await parallel([
    () => agentRetry(
      `Search breadth: medium. Repo: ${repoRoot}. Read-only research grounding this epic intent for a wave roadmap. ` +
      `GROUND every assumption by view and CORRECT any code-blind claim (the canonical catch: an intent that asserts ` +
      `how the engine is structured). Return conclusions + file:line evidence, not file dumps.\n\n` +
      `Read the grounded epic intent at \`${runDir}/intent.md\`.`,
      { label: 'research', phase: 'research', agentType: 'Explore' }
    ),
  ])).filter(Boolean)
  findings.research = research.join('\n\n') || '(research returned nothing)'

  // --- ONE cto-advisor over the whole epic --------------------------------
  phase('decompose')
  const cto = await agentRetry(
    `You are the strategic/feasibility gate for a roadmap Phase E decomposition (repo ${repoRoot}). ` +
    `Produce an EPIC-LEVEL wave breakdown (advisory — NOT an implementation) given the intent + the grounded research ` +
    `below. Be blunt about scope; recommend SIMPLIFY/eject where honest. A SIMPLIFY is a defensible verdict to FOLD ` +
    `into the roadmap, NOT a blocker. Set interrupt=true ONLY for a genuine ADR-018 crit-1/2/3/5 blocker. Also set ` +
    `has_ui=true if any wave of this epic introduces or materially modifies a user-facing UI surface (drives the ` +
    `conditional ui-spec dispatch, ADR-062 §4 / ADR-063 §D6); else false.\n\n` +
    `Read the grounded epic intent at \`${runDir}/intent.md\`.\n\nRESEARCH:\n${findings.research}`,
    { label: 'cto-advisor', phase: 'decompose', agentType: 'cto-advisor', schema: CTO_SCHEMA }
  )
  findings['cto-advisor'] = cto ? cto.report : '(cto-advisor died)'
  if (cto && cto.interrupt) { interruptFinding('decompose', cto.interruptReason) }

  // --- ONE architect-review (PRE) over the whole epic ---------------------
  const archPre = await agentRetry(
    `Architectural gate (PRE-implementation) for the whole epic '${epicSlug}' (repo ${repoRoot}): wave decomposition, ` +
    `ADR territory, governing ADRs cited per wave, carryover folds. Advisory. interrupt=true only for ADR-018 ` +
    `crit-1/2/3/5. Set has_ui=true if any wave introduces or materially modifies a UI surface (REQUIRED — drives the ` +
    `conditional ui-spec dispatch, ADR-062 §4 / ADR-063 §D6).\n\n` +
    `Read the grounded epic intent at \`${runDir}/intent.md\`.\n\nRESEARCH:\n${findings.research}\n\nCTO:\n${findings['cto-advisor']}`,
    { label: 'architect-review', phase: 'decompose', agentType: 'architect-review', schema: ARCH_PRE_SCHEMA }
  )
  findings['architect-review'] = archPre ? archPre.report : '(architect-review died)'
  if (archPre && archPre.interrupt) { interruptFinding('decompose', archPre.interruptReason) }

  // --- ONE ui-spec, CONDITIONAL on has_ui (T-106 wires the gate) ---------
  const ctoUi = !!(cto && cto.has_ui)
  const archUi = !!(archPre && archPre.has_ui)
  const wantUiOp = _a.wantUi === true
  let ui = null
  if (ctoUi || archUi || wantUiOp) {
    ui = await agentRetry(
      `UI spec for epic '${epicSlug}' (repo ${repoRoot}): concrete visual requirements + error-state UX for any NEW or ` +
      `materially-modified UI surface in this epic. Advisory.\n\nRead the grounded epic intent at \`${runDir}/intent.md\`.\n\n` +
      `CTO:\n${findings['cto-advisor']}\n\nARCHITECT:\n${findings['architect-review']}`,
      { label: 'ui-spec', phase: 'decompose', agentType: 'ui-spec', schema: ADVISOR_SCHEMA }
    )
    findings['ui-spec'] = ui ? ui.report : '(ui-spec died)'
  } else {
    log(`ui-spec: skipped (cto.has_ui=${ctoUi}, architect.has_ui=${archUi}, wantUi=${wantUiOp}) — no UI surface in this epic`)
  }

  // --- ONE pm-spec(spec) over the whole epic ------------------------------
  phase('spec')
  const specDraft = await agentRetry(
    `You are pm-spec. Author the buildable SPEC for the WHOLE epic '${epicSlug}' (repo ${repoRoot}) — one narrative ` +
    `spec with numbered AC-NNN acceptance atoms covering every wave of the epic. Do NOT slice into tickets yourself ` +
    `(spec-decomposer owns the slice next) and do NOT split into per-wave files (the render pass groups by wave_slug ` +
    `afterward). Return \`markdown\` = the spec. ` +
    // ADR-113 D2 — pass-by-path handoff: write the spec to the run folder so downstream dispatches
    // (spec-decomposer, author, per-wave render) read it by path instead of re-inlining the whole epic spec.
    `REQUIRED: in addition to returning \`markdown\`, WRITE the SAME spec to \`${runDir}/spec.md\` using your Write ` +
    `tool (write ONLY under ${runDir} — never docs/step-3-specs/**); peer agents read the binding spec from there.\n\n` +
    `Read the grounded epic intent at \`${runDir}/intent.md\`.\n\nCTO:\n${findings['cto-advisor']}\n\nARCHITECT:\n${findings['architect-review']}\n\n` +
    `UI-SPEC:\n${findings['ui-spec'] || '(no UI surface in this epic — ui-spec skipped)'}`,
    { label: 'pm-spec', phase: 'spec', agentType: 'pm-spec', schema: SPEC_SCHEMA }
  )
  const specText = specDraft ? (specDraft.markdown || '') : ''
  findings['pm-spec'] = specText || '(pm-spec returned empty epic spec)'
  if (!specText.trim()) {
    interruptFinding('spec', 'pm-spec returned empty epic spec')
    return { track: 'roadmap', phase: 'E', epicSlug, roadmapMarkdown: '', waves: [], findings, criterionFindings, surfaceRequired: true, surfaceType: 'unknown' }
  }

  // --- ONE spec-decomposer over the whole epic. Emits FLAT tickets[], each ticket carries wave_slug -----
  phase('decompose-tickets')
  const epicKeyHint = (epicSlug.split('-').map(w => w[0] || '').join('') || 'E').toUpperCase()
  const decomp = await agentRetry(
    `spec-decomposer: decompose this EPIC spec into self-contained tickets. Repo: ${repoRoot}. Return a FLAT \`tickets\` ` +
    `array — every ticket carries a \`wave_slug: string\` field that assigns it to a wave (kebab 'wave-N-<short-name>'). ` +
    `Tickets within a wave are sequential structure for ONE writer (ADR-062 §3 — one implementer per wave); ` +
    `\`depends_on\` within a wave is a SEQUENCING HINT for that one writer, not a parallel-merge contract. Across waves, ` +
    `\`depends_on\` IS a parallel-merge contract (the cross-wave seam). Within-wave shared planned_files is CORRECT under ` +
    `the new doctrine (one sequential writer); the v1 'disjoint planned_files within a wave' rule (ADR-048) applies only ` +
    `ACROSS waves (parallel waves via /launch) under ADR-062.\n\n` +
    `EACH TICKET: a stable key matching ^[A-Z][A-Z0-9]*-[A-Z0-9]+$ (SINGLE hyphen, e.g. ${epicKeyHint}-T1, ${epicKeyHint}-T2), ` +
    `description, depends_on (KEYS of tickets it directly depends on; [] for a leaf), planned_files (NON-EMPTY), ` +
    `acceptance (the AC-NNN atom IDs from the spec this ticket claims — every AC-NNN in the spec must be claimed by >=1 ` +
    `ticket; ADR-044), gates (recommended gate agents), manual_review_required, and wave_slug (REQUIRED).\n\n` +
    `Read the binding epic spec at \`${runDir}/spec.md\`.`,
    { label: 'spec-decomposer', phase: 'decompose-tickets', agentType: 'spec-decomposer', schema: TICKETS_SCHEMA }
  )
  const tickets = (decomp && Array.isArray(decomp.tickets)) ? decomp.tickets : []
  findings['spec-decomposer'] = tickets.length
    ? tickets.map(t => `- [${t.wave_slug || '?'}] ${t.key}: ${String(t.description || '').split('\n')[0]} [deps: ${(t.depends_on || []).join(',') || 'none'}; files: ${(t.planned_files || []).join(', ') || 'NONE'}]`).join('\n')
    : '(spec-decomposer returned no tickets)'
  if (!tickets.length) {
    interruptFinding('decompose-tickets', 'spec-decomposer returned no tickets')
    return { track: 'roadmap', phase: 'E', epicSlug, roadmapMarkdown: '', waves: [], findings, criterionFindings, surfaceRequired: true, surfaceType: 'unknown' }
  }

  // Graph validation (fail-closed). Validate the WHOLE epic's tickets graph; key shape, uniqueness,
  // orphan deps, cycle. wave_slug is a required field on each ticket.
  const graphErrors = validateTicketGraph(tickets)
  for (const t of tickets) {
    if (!t.wave_slug || !SLUG_RE.test(t.wave_slug)) graphErrors.push(`ticket '${t.key}' has invalid/missing wave_slug '${t.wave_slug || ''}'`)
  }
  // PEC-T5: wave-partition-aware validation (inter-wave ordering DAG + across-wave disjoint-sink). Runs
  // only when the flat graph + wave_slugs are well-formed (else the errors above already fail closed),
  // so the reachability walk operates on an acyclic, wave-tagged graph.
  if (!graphErrors.length) {
    // ADR-121: auto-derive cross-wave serialization edges for resolvable shared-sink ordering gaps BEFORE
    // the partition check — converts the old expensive late hard-fail into a deterministic serialization (the
    // funnel spend is salvaged). A genuine inter-wave CYCLE is still caught by validateWavePartition below.
    for (const e of deriveCrossWaveSerialization(tickets)) {
      warn('decompose-tickets', `AUTOSERIAL-${e.later}`,
        `auto-serialized cross-wave shared sink: '${e.later}' (${e.lw}) now depends_on '${e.earlier}' (${e.ew}) ` +
        `for shared planned_files [${e.sinks.join(', ')}] — derived from wave build order (ADR-121). The edge lives ` +
        `in the flat epic graph + build order only; renderWaveSchema strips it from the per-wave file (ADR-113).`)
    }
    for (const e of validateWavePartition(tickets)) graphErrors.push(e)
  }
  if (graphErrors.length) {
    for (const e of graphErrors) criterionFindings.push({
      gate: 'decompose-tickets', id: 'DECOMP-GRAPH', severity: 'high',
      criterion_match: 'crit-1', recommended_disposition: 'ESCALATE', detail: e,
    })
    return { track: 'roadmap', phase: 'E', epicSlug, roadmapMarkdown: '', waves: [], findings, criterionFindings, surfaceRequired: true, surfaceType: 'validate-fail' }
  }

  // --- Group flat tickets[] by wave_slug (preserving ticket input order) --
  const ticketsByWave = new Map()
  const waveOrder = []                              // wave_slug build order, by first appearance
  for (const t of tickets) {
    if (!ticketsByWave.has(t.wave_slug)) { ticketsByWave.set(t.wave_slug, []); waveOrder.push(t.wave_slug) }
    ticketsByWave.get(t.wave_slug).push(t)
  }

  // --- WAVE CONTEXT-BUDGET WARN per grouped wave (ADR-086 D2/D4 — T4a). Each wave_slug group is one
  // implementer build; estimate its consumption and WARN AT PLANNING TIME if it exceeds the 60% line. ---
  for (const ws of waveOrder) {
    const est = estimateWaveTokens(ticketsByWave.get(ws) || [], fileBytes)
    if (est.over) warn('context-budget', `WAVE-BUDGET-${ws}`, budgetWarnDetail(ws, est))
    else log(`context-budget: OK — wave '${ws}' predicted ~${est.predicted.toLocaleString()} tokens (${est.pct}% of budget${est.usedFallback ? ', coarse' : ''})`)
  }

  // --- ATOM-CHAIN GUARD over the epic tickets (ADR-086 / handoff T6). Warn on any ticket with empty
  // acceptance[] while the epic spec mints AC-NNN atoms (phantom dropped-scope GAP guard; warn, not block). ---
  if (/\bAC-\d{3}\b/.test(specText || '')) {
    for (const t of tickets) {
      if (!Array.isArray(t.acceptance) || t.acceptance.length === 0) {
        warn('atom-chain', `ATOM-CHAIN-${t.key}`,
          `hand-fed ticket ${t.key} broke the atom chain — the epic spec mints AC-NNN atoms but this ticket carries ` +
          `none in acceptance[]; the coverage check will read a phantom dropped-scope GAP. See the spec-decomposer ` +
          `contract (every AC-NNN claimed by >=1 ticket; ADR-044/ADR-086 T6). Warn, not block.`)
      }
    }
  }

  // --- Author the epic-level roadmap.md once, given the binding tickets[]/grouping. ----
  // The roadmap is the durable overview (thesis, per-wave skeletons, ejected items, build order); the
  // binding tickets[] is the spec-decomposer output, and the per-wave specs come from the render pass.
  phase('author')
  const jamSourceDir = `docs/step-2-planning/jam-${_a.jamSlug || epicSlug}/source/`
  const draft = await agentRetry(
    `Author the COMPLETE roadmap markdown for epic '${epicSlug}'. You are the author — return the full \`markdown\` ` +
    `content of roadmap.md: a thesis, any load-bearing research correction, fat per-wave skeletons (scope, governing ` +
    `ADRs, dependency edges, known gaps), ejected items, and a build order. Honour the cto + architect + ui-spec + ` +
    `the BINDING tickets[] slice + wave grouping below. Do NOT re-slice; the slicer already owns that.\n` +
    `ALSO return \`waves\`: an ORDERED array of { slug, skeleton } — one per wave in build order, matching the ` +
    `wave_slug values in the binding slice (the order is the wave-build order). The skeleton is each wave's complete ` +
    `fat-skeleton text. Ejected/out-of-scope items are NOT waves.\n` +
    `SOURCE DISPOSITION (ADR-103 W2 — the IN bookend; REQUIRED when a jam backs this epic). Glob \`${jamSourceDir}*.md\`. ` +
    `If it has files, the roadmap markdown MUST contain a top-level \`## Source disposition\` section with one bullet per ` +
    `source file: '- <slug>: <disposition>' where <slug> is the filename without .md and <disposition> is EXACTLY one of ` +
    `'wave:<wave-slug>' (absorbed by that wave), 'non-goal' (deliberately out of scope), or 'defer:<target>' (shelved, ` +
    `target = an ideas/backlog path). EVERY source slug must appear — a roadmap that drops a decided jam idea silently is ` +
    `the exact bug this gate blocks; the lock will HALT on any unaccounted source. If the glob is empty (no jam), omit the ` +
    `section.\n\n` +
    `Read the grounded epic intent at \`${runDir}/intent.md\` and the binding epic spec at \`${runDir}/spec.md\`.\n\n` +
    `RESEARCH:\n${findings.research}\n\nCTO:\n${findings['cto-advisor']}\n\nARCHITECT:\n${findings['architect-review']}\n\n` +
    `UI-SPEC:\n${findings['ui-spec'] || '(no UI surface — ui-spec skipped)'}\n\n` +
    `WAVE GROUPING (from spec-decomposer; build order):\n` +
    waveOrder.map(s => `- ${s}: ${(ticketsByWave.get(s) || []).map(t => t.key).join(', ')}`).join('\n'),
    { label: 'author', phase: 'author', agentType: 'pm-spec', schema: AUTHOR_SCHEMA }
  )
  let markdown = draft ? (draft.markdown || '') : ''
  let authoredWaves = (draft && Array.isArray(draft.waves)) ? draft.waves : []
  if (!markdown.trim()) {
    interruptFinding('author', 'authoring agent returned empty markdown')
    return { track: 'roadmap', phase: 'E', epicSlug, roadmapMarkdown: '', waves: [], findings, criterionFindings, surfaceRequired: true, surfaceType: 'unknown' }
  }

  phase('self-qa')
  const qa = await agentRetry(
    `Read-only self-QA of this roadmap draft (repo ${repoRoot}). Re-verify the draft's load-bearing claims BY VIEW ` +
    `(re-grep, re-read cited file:line). Recommend disposition LOCK (lock-quality as-is) or CONTINUE (name concrete ` +
    `tunings). Return your full reasoning in \`report\` and any tunings[].\n\nDRAFT:\n${markdown}`,
    { label: 'self-qa', phase: 'self-qa', agentType: 'planner', schema: QA_SCHEMA }
  )
  findings['round-1-recommended-reply'] = qa ? qa.report : '(planner self-QA died — finalized un-QA\'d)'

  if (attended) {
    // Legacy ADR-030 round: return draft + QA without finalizing; orchestrator presents the boundary.
    // Attended Phase E STOPS at the roadmap round — the per-wave render is autonomous-only. (No examine
    // here — the examine fold-in is part of autonomous finalize, which an attended round does not run.)
    return {
      track: 'roadmap', phase: 'E', epicSlug, attended: true,
      roadmapMarkdown: markdown, waves: [], selfQA: qa || null, findings, criterionFindings, warnFindings,
      capturedIntent: (cap.captured ? capturedIntent : undefined),
      surfaceRequired: true, surfaceType: 'roadmap-round',
    }
  }

  // --- PEC-T13: examiner fold-in pass (AFTER self-qa, BEFORE finalize) -------------------------------
  // ONE examiner (Fable seat — reuse ADR-088/095/099 dispatch, NOT re-authored) reviews the self-qa'd
  // draft; its findings are FOLDED INTO the draft by the existing finalize pm-spec (examiner is review-only
  // and authors nothing — ADR-088 D2). FOLD-IN, NOT a gate (AC-033): no halt, no operator round-trip, NO
  // new halt class — a severe (RETHINK) verdict rides the EXISTING decision-log surface (findings), folded
  // best-effort. LEDGER (ADR-088 D4): the engine has NO filesystem (ADR-039 contract 2), so it CANNOT write
  // docs/step-3-specs/_fable-spend.jsonl. It returns the dispatch in `examinerDispatches[]`; the ORCHESTRATOR
  // appends ONE _fable-spend.jsonl line per entry post-run — the /examine O_APPEND snippet, VERBATIM
  // (CLAUDE.md "if you dispatch an examiner outside /examine, you append the ledger line yourself at the
  // dispatch site"; token counts come from the examiner agent journal, the measure-run --per-agent source).
  const examinerDispatches = []
  let examineTunings = []
  phase('examine')
  const exam = await agentRetry(
    `examiner: review this self-qa'd roadmap draft for epic '${epicSlug}' (repo ${repoRoot}). Emit GOOD/BAD/UGLY, ` +
    `a verdict (SOUND | FOLD-IN-REQUIRED | RETHINK), and prescriptive F-NNN findings. Review-only — author nothing. ` +
    `This is a FOLD-IN pass: any findings will be folded into the draft before finalize (no halt, no gate).\n\n` +
    `DRAFT:\n${markdown}`,
    { label: 'examine', phase: 'examine', agentType: 'examiner', schema: EXAMINE_SCHEMA }
  )
  if (exam) {
    examinerDispatches.push({ target: `roadmap:${epicSlug}`, verdict: exam.verdict, over_envelope: false })
    findings['examiner-plan'] = `VERDICT: ${exam.verdict}\n\n${exam.summary || ''}\n\n` +
      (Array.isArray(exam.findings) ? exam.findings.map(f => `- ${f.id} [${f.severity || '?'}]: ${f.prescription}`).join('\n') : '')
    if (exam.verdict !== 'SOUND' && Array.isArray(exam.findings)) {
      examineTunings = exam.findings.map(f => `[examiner ${f.id}] ${f.prescription}`)
    }
    log(`examine: ${exam.verdict} (${(exam.findings || []).length} findings) — fold-in, no halt (AC-033)`)
  }

  // Autonomous finalize (ADR-054): fold self-QA tunings AND examiner findings (PEC-T13) into the roadmap;
  // judgment-call items go under '## Open refinements'. LOCK + SOUND with nothing to fold -> draft is final.
  const qaTunings = (qa && qa.disposition === 'CONTINUE' && Array.isArray(qa.tunings)) ? qa.tunings : []
  const foldTunings = qaTunings.concat(examineTunings)
  if (foldTunings.length) {
    phase('finalize')
    const finalized = await agentRetry(
      `Produce the FINAL roadmap markdown by folding the planner self-QA tunings AND the examiner fold-in ` +
      `findings (prefixed '[examiner F-NNN]') into the draft. Fold the mechanically-clear ones directly; list ` +
      `any that need a judgment call under a '## Open refinements (planner)' section. Return the full ` +
      `\`markdown\` AND the (possibly-updated) ORDERED \`waves\` array { slug, skeleton } matching the final roadmap.\n` +
      `PRESERVE the '## Source disposition' section VERBATIM if the draft has one (ADR-103 W2 — every jam source must ` +
      `stay accounted; the lock will HALT on any source dropped from it). If a tuning re-homes a capability, update that ` +
      `source's disposition line accordingly — never delete a source bullet.\n\n` +
      `DRAFT:\n${markdown}\n\nWAVES:\n${JSON.stringify(authoredWaves)}\n\nTUNINGS:\n- ${foldTunings.join('\n- ')}`,
      { label: 'finalize', phase: 'finalize', agentType: 'pm-spec', schema: AUTHOR_SCHEMA }
    )
    if (finalized && finalized.markdown && finalized.markdown.trim()) markdown = finalized.markdown
    if (finalized && Array.isArray(finalized.waves) && finalized.waves.length) authoredWaves = finalized.waves
  }

  // Allow an explicit args.waves override of the work-list (e.g. operator-curated). Default to the
  // wave order from the binding slicer output (waveOrder); fall back to the author's emitted waves[].
  const waveListSrc = (Array.isArray(_a.waves) && _a.waves.length) ? _a.waves
                     : (authoredWaves.length ? authoredWaves
                     : waveOrder.map(s => ({ slug: s, skeleton: '' })))

  // --- ONE pm-spec(render) groups the binding flat tickets[] by wave_slug and authors per-wave files. ---
  // Replaces the v1 per-wave fan-out loop entirely (no per-wave cto/architect/ui-spec/pm-spec/spec-decomposer).
  // The '# Wave:' parseable schema is rendered DETERMINISTICALLY from the binding tickets[] (machine-parsed
  // by wave-manifest.py); the renderer authors only the per-wave per-ticket BUILD PROSE (-prompts.md).
  const wavesOut = []
  const wavesFailed = []                            // ADR-113 D3: per-wave renders that returned null after retry
  if (fanOut && waveListSrc.length) {
    for (const w of waveListSrc) {
      if (!w || !w.slug || !SLUG_RE.test(w.slug)) {
        interruptFinding('render', `invalid wave slug '${w && w.slug}'`)
        break
      }
      const wTickets = ticketsByWave.get(w.slug) || []
      if (!wTickets.length) {
        log(`render: wave '${w.slug}' has no tickets in the binding slice — skipping`)
        continue
      }
      const wMarkdown = renderWaveSchema(w.slug, wTickets)
      const wDraft = await agentRetry(
        `You are pm-spec, the integrator/renderer. Author the per-ticket BUILD PROSE (\`promptsMarkdown\`) for wave '${w.slug}' ` +
        `of epic '${epicSlug}'. The buildable '# Wave:' ticket schema is ALREADY rendered (below) — do NOT reproduce or ` +
        `reformat it; write the human-facing build guidance per ticket (context, approach, gotchas, acceptance), keyed to ` +
        `the EXACT ticket keys.\n\n` +
        `WAVE SCHEMA (rendered — authoritative, do not restate):\n${wMarkdown}\n\nTICKETS (binding slice for this wave):\n${JSON.stringify(wTickets, null, 2)}\n\n` +
        `Read the binding epic spec at \`${runDir}/spec.md\`.\n\nWAVE SKELETON:\n${w.skeleton || '(none — see the roadmap)'}\n\n` +
        `ARCHITECT:\n${findings['architect-review']}\n\nUI-SPEC:\n${findings['ui-spec'] || '(no UI surface in this epic)'}`,
        { label: `pm-spec-render:${w.slug}`, phase: 'author', agentType: 'pm-spec', schema: PROMPTS_SCHEMA }
      )
      // ADR-113 D3: a render that still returns null after retry loses only the BUILD PROSE for this wave
      // (the deterministic '# Wave:' schema is computed from the binding tickets, not the agent). Do NOT push
      // a wave with empty prose — record the slug in wavesFailed[] and continue; surfaceRequired flips below.
      if (!wDraft) {
        wavesFailed.push(w.slug)
        log(`render: wave '${w.slug}' build-prose render returned null after retry — recorded in wavesFailed[], not pushing empty wave`)
        continue
      }
      const wPrompts = wDraft.promptsMarkdown || ''
      wavesOut.push({ slug: w.slug, waveSpecMarkdown: wMarkdown, wavePromptsMarkdown: wPrompts, tickets: wTickets })
    }
  } else if (fanOut && !waveListSrc.length) {
    log('render: no waves to render — roadmap authored, no per-wave specs')
  }

  // ADR-113 D3: a non-empty wavesFailed[] surfaces (a silently-broken wave must not reach persist).
  // surfaceType stays 'validate-fail' when criterionFindings exist (the pre-existing class); when waves
  // failed with NO criterionFindings the cause is a fan-out render exhaustion -> 'unknown'.
  const eSurface = criterionFindings.length > 0 || wavesFailed.length > 0
  const eSurfaceType = criterionFindings.length > 0 ? 'validate-fail' : (wavesFailed.length > 0 ? 'unknown' : null)
  return {
    track: 'roadmap', phase: 'E', epicSlug,
    roadmapMarkdown: markdown, waves: wavesOut, wavesFailed, findings, criterionFindings, warnFindings,
    examinerDispatches,                             // PEC-T13: orchestrator O_APPENDs one _fable-spend.jsonl line per entry
    capturedIntent: (cap.captured ? capturedIntent : undefined),
    surfaceRequired: eSurface,
    surfaceType: eSurfaceType,
  }
}

// ===========================================================================
// PHASE W (standalone) — plan one named wave. Mirrors a single fan-out iteration.
// ===========================================================================
const rW = await runPhaseW(waveSlug, intent, [], attended, '')
for (const [k, v] of Object.entries(rW.findings)) findings[k] = v
for (const cf of rW.criterionFindings) criterionFindings.push(cf)
for (const wf of (rW.warnFindings || [])) warnFindings.push(wf)   // ADR-086 D4: aggregate the wave's WARNs

if (attended) {
  return {
    track: 'roadmap', phase: 'W', epicSlug, waveSlug, attended: true,
    waveSpecMarkdown: rW.waveSpecMarkdown, wavePromptsMarkdown: rW.wavePromptsMarkdown, selfQA: rW.selfQA || null,
    findings, criterionFindings, warnFindings, surfaceRequired: true, surfaceType: 'roadmap-round',
  }
}

return {
  track: 'roadmap', phase: 'W', epicSlug, waveSlug,
  waveSpecMarkdown: rW.waveSpecMarkdown, wavePromptsMarkdown: rW.wavePromptsMarkdown, tickets: rW.tickets,
  findings, criterionFindings, warnFindings,
  surfaceRequired: criterionFindings.length > 0,
  surfaceType: criterionFindings.length > 0 ? 'validate-fail' : null,
}
