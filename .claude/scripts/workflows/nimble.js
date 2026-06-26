export const meta = {
  name: 'nimble',
  description: 'v2 nimble preset (production): explore -> implement (worktree) -> integrate (staleness-guarded) -> batch-gate, under the shared autonomy contract. Returns a structured payload the orchestrator persists via persist-run-artifacts.py (FLAG-1).',
  phases: [
    { title: 'explore', detail: '1 Explore agent validates codebase assumptions (nimble scope)' },
    { title: 'implement', detail: 'single implementer authors the change in an isolated worktree' },
    { title: 'integrate', detail: 'staleness-guarded --no-ff merge of the implementer commit into the working branch (in-place)' },
    { title: 'gate', detail: 'code-reviewer + spec-conformance (+ optional contextual), structured findings' },
  ],
}

// ===========================================================================
// THE v2 NIMBLE ENGINE. The chain is ~60 lines of control flow instead of a
// 5-phase state machine that re-injects the rules corpus every turn. Proven by
// the T4 spike (GO: orchestrator output -86%, 0 surfaces, quality held).
//
// FOUR STANDARDIZED CONTRACTS (T5a, from the spike findings):
//  1. Defensive args parse — `args` may arrive as a JSON string.
//  2. Returns a structured payload; the ORCHESTRATOR persists artifacts
//     (persist-run-artifacts.py) — scripts have no FS access, Explore can't Write.
//  3. The script COMPUTES the surface (criterionFindings + surfaceRequired);
//     the ORCHESTRATOR disposes judgment-class findings (auto APPLY/DEFER/DISMISS +
//     decision log, ADR-105) and halts ONLY on an execution-class block — scripts
//     cannot halt-and-wait. surfaceRequired is advisory for judgment-class (ADR-105).
//  4. Implement runs in an ISOLATED WORKTREE, then a staleness-guarded integrate
//     merges the commit into the working branch (ADR-046, supersedes the original
//     in-place choice). In-place collided with block-source-edits.sh, which blocks
//     source-extension writes in the main tree but ALLOWS them in a worktree.
//
// args: { runDir, repoRoot, task, contextual?, baseRef?, baseSha? }
//   contextual: optional extra gate agentType picked by file-type
//     (ui-review | db-migration-reviewer | security-auditor). null/absent = none.
//   baseRef: working-branch HEAD captured by the orchestrator pre-launch; the
//     integrate staleness guard + the gate diff use it as the stable base. Absent
//     => guard falls back to current HEAD (degraded; warned).
//   baseSha: working-branch tip SHA captured by the orchestrator at dispatch
//     (`git rev-parse HEAD`). Embedded as an UNCONDITIONAL STEP 0 in the implement
//     brief (`git fetch . && git reset --hard <baseSha>`) — worktrees are known to
//     base off stale session-start state, not the dispatch-time tip (ADR-085 D2).
//     Absent => fall back to naming the working branch with the existing
//     protocol-guard language (today's behaviour, unchanged semantics). The SHA
//     arrives via args ONLY — scripts have no git/FS access (ADR-039 contract 2).
// ===========================================================================

const _a = typeof args === 'string' ? JSON.parse(args) : (args || {})        // contract 1
const { runDir, repoRoot, task } = _a
const contextual = _a.contextual || null
const baseRef = _a.baseRef || null
const baseSha = _a.baseSha || null
// ADR-102 / W3DMR-T4: optional planned-files for the single nimble task, surfaced by the orchestrator via
// args. Drives the build-role model tier (computeBuildTier). Absent/empty => the tier defaults to 'opus'
// (default-to-Opus-when-uncertain). NOT a required arg — nimble works identically when it is unset.
const plannedFiles = Array.isArray(_a.plannedFiles) ? _a.plannedFiles : []
// SHR3-T3 / AC-008 — LAUNCHING-CONTEXT ISOLATION (ADR-046, security-relevant). When nimble is launched from
// an AUTONOMOUS background context (the queue-chew daemon / a background Workflow), the launching session's
// interactive HEAD must NOT be mutated by this run. The implement step already isolates in a worktree
// (contract 4 / L237), but the INTEGRATE step merges "IN PLACE in the main working tree" — which, in a
// background launch, IS the launching tree, so its `git merge --no-ff` would flip the launching HEAD. When
// the orchestrator surfaces `workTree` (the dedicated worktree path of the launching autonomous actor, e.g.
// the chew's QC_WORKTREE), integrate is SCOPED to that path (`git -C <workTree>`) so the merge lands on the
// isolated worktree and the launching/operator tree's HEAD is untouched. Absent => integrate runs in the
// current tree (today's interactive-session behaviour, unchanged). NON-GOAL (ADR-062 §3): this isolates the
// AUTONOMOUS-actor launch path only — the orchestrated in-place wave-builder stays unisolated by design.
const workTree = (typeof _a.workTree === 'string' && _a.workTree) ? _a.workTree : null
if (!runDir || !repoRoot || !task) {
  throw new Error(`nimble: missing required args (runDir/repoRoot/task). Got keys: ${Object.keys(_a).join(',') || '<none>'}`)
}

// Shape guard for values that flow into the integrate agent's shell commands (CR-001 parity with
// orchestrated): reject anything that isn't a plausible git sha before interpolation.
const SHA_RE = /^[0-9a-f]{7,40}$/i
// Path-shape guard for `workTree` (SHR3-T3): it flows into the integrate agent's `git -C <workTree>` shell
// command, so reject anything that could break out of argv position before interpolation. Allow only a
// plausible filesystem path (no shell metacharacters / quotes / newlines). A miss => treat as unset (run in
// the current tree) rather than interpolate an untrusted value.
const WORKTREE_RE = /^[A-Za-z0-9._/-]+$/
const safeWorkTree = (workTree && WORKTREE_RE.test(workTree)) ? workTree : null

// ---------------------------------------------------------------------------
// DYNAMIC BUILD-ROLE MODEL TIER (ADR-102) — single-task variant for nimble.
// Nimble has no tickets[] (its args are {runDir,repoRoot,task,contextual?,baseRef?,baseSha?}). Compute
// the tier off the nimble task's planned-files IF surfaced via args (`plannedFiles: string[]`), else
// default 'opus'. Identical pure/inline shape as orchestrated.js's computeBuildTier (ADR-039 forbids the
// shared module — intentional small duplication, same constraint as the duplicated estimateWaveTokens).
// Codomain is structurally EXACTLY {'sonnet','opus'} (ADR-099 floor; no Fable per ADR-095). The function
// is DEFINED here; threading onto the dispatch is T4.
const BUILD_TIER = { SONNET: 'sonnet', OPUS: 'opus' }
// Normalize a path purely (no FS): collapse `./`, resolve `..`. Returns { norm, suspicious } —
// `suspicious` true for an absolute path or a `..` escape (poisons every cheap branch → Opus). Mirror of
// orchestrated.js.
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
// Cosmetic-only allowlist (docs/, top-level *.md, tests/) — allowlist-positive, normalized-prefix,
// non-spoofable (rejects ../ and absolute escapes into source). Mirror of orchestrated.js.
// Body kept BYTE-IDENTICAL to orchestrated.js (canonical) — test-classifier-drift.sh goes RED on drift (SHR3-T2).
function isCosmeticOnlyPath(p) {
  const { norm, suspicious } = normalizePlannedPath(p)
  if (suspicious || !norm) return false          // absolute / ..-escape / empty — NOT cosmetic
  const parts = norm.split('/')
  if (norm === 'docs' || norm.startsWith('docs/')) return true     // docs/**
  if (norm === 'tests' || norm.startsWith('tests/')) return true   // tests/**
  if (parts.length === 1 && /\.md$/i.test(norm)) return true       // top-level *.md
  return false
}
// computeBuildTier(plannedFiles) -> 'sonnet' | 'opus' for the single nimble task.
//   - docs-only (every surfaced planned file cosmetic-only, ≥1 file) → sonnet
//   - trivial   (≤1 surfaced planned file, no escape) → sonnet  (nimble has no AC list; file-count is the proxy)
//   - else / escape / no planned-files surfaced / malformed → opus (default-to-Opus-when-uncertain)
function computeBuildTier(plannedFiles) {
  if (!Array.isArray(plannedFiles) || plannedFiles.length === 0) return BUILD_TIER.OPUS   // none surfaced → Opus
  const files = []
  for (const f of plannedFiles) if (typeof f === 'string' && f) files.push(f)
  if (files.length === 0) return BUILD_TIER.OPUS
  // docs-only: every surfaced file cosmetic-only
  if (files.every(isCosmeticOnlyPath)) return BUILD_TIER.SONNET
  // a crafted escape/absolute entry poisons the trivial branch (AC-016) → Opus
  if (files.some(f => normalizePlannedPath(f).suspicious)) return BUILD_TIER.OPUS
  // trivial: a single surfaced planned file (the nimble proxy for "small")
  if (files.length <= 1) return BUILD_TIER.SONNET
  return BUILD_TIER.OPUS                                                                  // codomain clamp → Opus
}
// Always-logged rationale + modelRouting audit (AC-008/AC-009), nimble shape.
function buildModelRouting(plannedFiles) {
  const tier = computeBuildTier(plannedFiles)
  const files = (Array.isArray(plannedFiles) ? plannedFiles : []).filter(f => typeof f === 'string' && f)
  const fileCount = files.length
  const docsOnly = fileCount > 0 && files.every(isCosmeticOnlyPath)
  let rule
  if (tier === BUILD_TIER.SONNET && docsOnly) rule = `docs-only diff (${fileCount} file${fileCount === 1 ? '' : 's'}, all cosmetic docs/**·*.md·tests/**)`
  else if (tier === BUILD_TIER.SONNET) rule = `trivial (${fileCount} file${fileCount === 1 ? '' : 's'})`
  else rule = fileCount === 0 ? `default (no planned-files surfaced)` : `default (${fileCount} files)`
  return { tier, rule, fileCount, acCount: 0, docsOnly }
}

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
const IMPLEMENT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['status', 'sha', 'report'],
  properties: {
    status: { type: 'string', enum: ['complete', 'refused', 'blocked'] },
    sha: { type: 'string' },                    // commit sha on the worktree branch ('' if none)
    files_changed: { type: 'array', items: { type: 'string' } },
    report: { type: 'string' },                 // COMPLETION_REPORT or REFUSAL rationale
    summary: { type: 'string' },                // optional (ADR-083 D2): one-line what-changed, <=300 chars,
                                                // fed to the gates instead of the full report (gates also inspect git)
  },
}
const INTEGRATE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['status', 'integrated_head', 'report'],
  properties: {
    status: { type: 'string', enum: ['integrated', 'stale_refused', 'conflict', 'noop'] },
    integrated_head: { type: 'string' },
    base_sha: { type: 'string' },               // the pre-merge base (stable diff base)
    report: { type: 'string' },
  },
}

const CRIT = `For each finding set criterion_match per ADR-018 (none = auto-disposable; ` +
  `crit-1 architecture / crit-2 scope / crit-3 security / crit-4 operator-authority / crit-5 ambiguity) ` +
  `and recommended_disposition (APPLY/DEFER/DISMISS/ESCALATE).`

// Accumulators for the structured return (orchestrator persists from these).
const criterionFindings = []
const allFindings = []
const payload = {}
// A short-circuit surface (implement refused/blocked, integrate stale/conflict) returns early with
// the payload built so far; the orchestrator persists what exists + surfaces. Never throws on a fork.
function shortCircuit(extra) {
  return {
    track: 'nimble', ...payload, ...extra,
    contextualType: contextual,
    allFindings, criterionFindings,
    surfaceRequired: true,
  }
}

// --- explore -------------------------------------------------------------
phase('explore')
const exploreMap = (await parallel([
  () => agent(
    `Search breadth: medium. Repo: ${repoRoot}. Validate codebase assumptions for this task:\n\n${task}\n\n` +
    `Report the data shapes, file conventions, and existing patterns the implementer must match. Conclusions only.`,
    { label: 'explore', phase: 'explore', agentType: 'Explore' }
  ),
])).filter(Boolean)
payload.exploreMap = exploreMap

// --- implement (isolated worktree; contract 4 / ADR-046) -----------------
phase('implement')
// STEP 0 (ADR-085 D2): worktrees are known to base off stale session-start state, not the dispatch-time
// branch tip. When the orchestrator supplies a SHA (args-only — scripts have no git/FS access), embed an
// UNCONDITIONAL reset to it; otherwise fall back to the existing protocol-guard ancestry language.
const baseStep0 = (baseSha && SHA_RE.test(baseSha))
  ? `STEP 0 (unconditional, before any work): \`git fetch . && git reset --hard ${baseSha}\` — then verify ` +
    `\`git rev-parse HEAD\` matches ${baseSha}. Worktrees are known to base off stale session-start state, not the ` +
    `dispatch-time branch tip; this reset makes your base deterministic. Do NOT skip it.\n\n`
  : `STEP 0 (before any work): your worktree should be based on the current working branch tip. Run the ` +
    `base-check guard in your protocol (core/agents/_shared/implementer-protocol.md) and \`git reset --hard\` ` +
    `onto the working-branch tip if your worktree is rooted behind it — worktrees can base off stale session-start state.\n\n`
// --- DYNAMIC BUILD-ROLE MODEL TIER (ADR-102 / W3DMR-T4) --------------------
// Compute the tier off the surfaced planned-files (computeBuildTier is CALLED here — wire-to-consumer);
// 'opus' when none surfaced. Threaded as the additive `model:` key on THIS worktree implement dispatch
// ONLY (AC-006); the integrate dispatch stays unrouted (AC-007). Always-logged MODEL TIER brief (AC-008);
// the modelRouting audit rides the returned payload (AC-009 — no new write path).
const modelRouting = buildModelRouting(plannedFiles)
payload.modelRouting = modelRouting
const modelTierBrief = `MODEL TIER: ${modelRouting.tier} — ${modelRouting.rule}\n` +
  `(Build-role model tier, computed deterministically per ADR-102. This dispatch runs on '${modelRouting.tier}'. ` +
  `Tier is build-role-only; integrate stays Opus-pinned. Default-to-Opus on uncertainty.)\n\n`
log(`model-tier: nimble build dispatch routed to '${modelRouting.tier}' — ${modelRouting.rule}`)
const implementResult = await agent(
  modelTierBrief +
  `Nimble implementation in repo ${repoRoot}. Read prompt.md and spec.md (if present) from ${runDir} yourself.\n\n` +
  baseStep0 +
  `You are in an ISOLATED git WORKTREE — your edits land on your own worktree branch, not the working branch.\n\n` +
  `TASK:\n${task}\n\nExploration findings to honour:\n${exploreMap.join('\n\n')}\n\n` +
  `Implement end-to-end, run your own verification, then COMMIT your work on your worktree branch with a concise ` +
  `message. Return status (complete | refused | blocked), sha = your commit sha (run \`git rev-parse HEAD\`; '' if ` +
  `you made no commit), files_changed, report (COMPLETION_REPORT, or a REFUSAL rationale if this exceeds nimble scope), ` +
  `and summary — a single-line, <=300-char "what changed" the gates read instead of your full report (they also ` +
  `inspect the integrated diff via git; ADR-083 D2).`,
  { label: 'implement', phase: 'implement', agentType: 'implementer', isolation: 'worktree', model: modelRouting.tier, schema: IMPLEMENT_SCHEMA }
)
// FLAG: persist consumes `implementation` as the report STRING (unchanged contract); the structured
// fields (status/sha) drive integration only.
payload.implementation = implementResult ? (implementResult.report || '') : ''
const implSha = implementResult ? String(implementResult.sha || '').trim() : ''
if (!implementResult || implementResult.status !== 'complete' || !implSha || !SHA_RE.test(implSha)) {
  const why = !implementResult ? 'implementer died (null return)'
            : implementResult.status !== 'complete' ? implementResult.status
            : !implSha ? 'complete-but-no-sha' : 'complete-but-malformed-sha'
  criterionFindings.push({
    gate: 'implement', id: 'IMPL', severity: 'high',
    criterion_match: implementResult && implementResult.status === 'refused' ? 'crit-2' : 'crit-1',
    recommended_disposition: 'ESCALATE',
    detail: `nimble implement ${why}: ${(implementResult ? implementResult.report || '' : '').slice(0, 400)}`,
  })
  log(`implement: ${why} — short-circuit surface (nothing to integrate)`)
  return shortCircuit({ stoppedAt: 'implement' })
}

// --- integrate: staleness-guarded --no-ff merge into the working branch (in-place; ADR-046) ----
// Mirrors orchestrated's integrate: run the AC-5 staleness guard against a stable base, then merge by
// COMMIT SHA. Local worktree->working-branch merge only — never main, never push (operator boundary).
phase('integrate')
if (!baseRef) {
  log(`AC-5 WARN: no baseRef provided — staleness guard falls back to current HEAD (degraded). ` +
      `The orchestrator should pass the working-branch HEAD captured before launch.`)
}
// SHR3-T3 / AC-008: record + log the launching-context isolation decision (rides the returned payload — no
// new write path). When a background launching actor surfaced its worktree, integrate is scoped to it so the
// launching HEAD is not mutated; absent => interactive in-place (unchanged).
payload.integrateIsolation = safeWorkTree
  ? { isolated: true, workTree: safeWorkTree, why: 'autonomous-launch — integrate scoped to launching worktree (ADR-046)' }
  : { isolated: false, workTree: null, why: 'interactive in-place integrate (no launching worktree surfaced)' }
log(safeWorkTree
  ? `integrate: ISOLATED to launching worktree ${safeWorkTree} — launching/operator HEAD untouched (SHR3-T3/ADR-046)`
  : `integrate: in-place (interactive); no launching worktree surfaced`)
const guardBase = baseRef && SHA_RE.test(baseRef) ? baseRef : '$(git rev-parse HEAD)'
// SHR3-T3 / AC-008: when launched from an autonomous background context, scope every integrate git op to
// the launching actor's dedicated worktree (`git -C <workTree>`) so the merge does NOT flip the launching /
// operator interactive HEAD. `GC` is the per-op prefix the agent uses; empty => current tree (interactive,
// unchanged). The HEAD reads (integrated_head / base_sha) use the same scope so they observe the worktree.
const GC = safeWorkTree ? `git -C "${safeWorkTree}"` : 'git'
const integrateLocus = safeWorkTree
  ? `Run all git operations SCOPED to the launching actor's ISOLATED worktree at ${safeWorkTree} (use ` +
    `\`${GC} …\` for EVERY git command below) — this run was launched from an autonomous background context ` +
    `(e.g. the queue-chew daemon) and MUST NOT mutate the launching/operator interactive HEAD (SHR3-T3 / ADR-046).`
  : `Run IN PLACE in the main working tree.`
const integrate = await agent(
  `Integrate the nimble implementer's commit into the CURRENT working branch, in repo ${repoRoot}. ` +
  `${integrateLocus}\n\n` +
  `STEP 1 — staleness guard (load-bearing, AC-5). The substrate path resolves in both contexts (ADR-031). Run:\n` +
  `  bash "$([ -d .claude/scripts ] && echo .claude || echo core)/scripts/worktree-staleness-check.sh" ${guardBase} ${implSha}\n` +
  `If it exits non-zero, the commit is rooted behind the base (the stale case). Do NOT merge. Return ` +
  `status=stale_refused with the guard output in report.\n\n` +
  `STEP 2 — if the guard passes, record the current HEAD sha as base_sha FIRST (\`${GC} rev-parse HEAD\`), then merge with --no-ff:\n` +
  `  ${GC} merge --no-ff ${implSha} -m "nimble: integrate change"\n` +
  `If the merge conflicts, abort it (\`${GC} merge --abort\`), STOP, and return status=conflict with details.\n\n` +
  `Return status (integrated | stale_refused | conflict | noop), integrated_head (\`${GC} rev-parse HEAD\`), ` +
  `base_sha (the HEAD sha BEFORE you merged), and a report.`,
  { label: 'integrate', phase: 'integrate', agentType: 'implementer', schema: INTEGRATE_SCHEMA }
)
payload.integrate = integrate
if (!integrate || integrate.status !== 'integrated') {
  const st = integrate ? integrate.status : 'NULL'
  criterionFindings.push({
    gate: 'integrate', id: 'INTEGRATE', severity: 'critical',
    criterion_match: 'crit-1', recommended_disposition: 'ESCALATE',
    detail: `integration ${st}: ${integrate ? (integrate.report || '').slice(0, 400) : 'agent died'}`,
  })
  log(`integrate: ${st} — short-circuit surface (cannot gate an un-integrated change)`)
  return shortCircuit({ stoppedAt: 'integrate' })
}
log(`integrate: merged ${implSha.slice(0, 8)} -> ${(integrate.integrated_head || '').slice(0, 8)}`)

// --- batch-gate: code-reviewer + spec-conformance (+ optional contextual) over the INTEGRATED diff -
phase('gate')
const diffBase = (baseRef && SHA_RE.test(baseRef)) ? baseRef
  : (integrate.base_sha && SHA_RE.test(integrate.base_sha) ? integrate.base_sha
     : (integrate.integrated_head && SHA_RE.test(integrate.integrated_head) ? `${integrate.integrated_head}~1` : 'HEAD~1'))
// ADR-083 D2: feed the gates a one-line summary, not the full free-prose report (they inspect the
// integrated diff via git, so the prose is largely redundant). Fallback: first 300 chars of the report.
// payload.implementation (the full report string the persist contract consumes) stays unchanged.
const summary = (implementResult && implementResult.summary)
  || (payload.implementation || '').slice(0, 300)
const gateThunks = [
  () => agent(
    `Code-review the INTEGRATED change for this task in repo ${repoRoot} (inspect via \`git diff ${diffBase}..HEAD\` and reading files).\n\n` +
    `TASK:\n${task}\n\nIMPLEMENTER SUMMARY: ${summary}\n\nReturn verdict + findings per the schema. ${CRIT}`,
    { label: 'gate:code-reviewer', phase: 'gate', agentType: 'code-reviewer', schema: FINDINGS_SCHEMA }
  ),
  () => agent(
    `Spec-conformance check in repo ${repoRoot}: does the integrated change satisfy spec.md / the task ACs at ${runDir}? ` +
    `Inspect \`git diff ${diffBase}..HEAD\`.\n\n` +
    `TASK:\n${task}\n\nIMPLEMENTER SUMMARY: ${summary}\n\nReturn verdict (CONFORMS/DRIFT/GAP) + findings per the schema. ${CRIT}`,
    { label: 'gate:spec-conformance', phase: 'gate', agentType: 'spec-conformance', schema: FINDINGS_SCHEMA }
  ),
]
if (contextual) {
  gateThunks.push(() => agent(
    `Contextual review (${contextual}) of the integrated change for this task in repo ${repoRoot} (\`git diff ${diffBase}..HEAD\`).\n\nTASK:\n${task}\n\n` +
    `IMPLEMENTER SUMMARY: ${summary}\n\nReturn verdict + findings per the schema. ${CRIT}`,
    { label: `gate:${contextual}`, phase: 'gate', agentType: contextual, schema: FINDINGS_SCHEMA }
  ))
}
const gateResults = await parallel(gateThunks)
const [review, conformance, contextualReview] = gateResults

// --- consolidated-surface computation (contract 3; ADR-036) --------------
for (const [g, res] of [['code-reviewer', review], ['spec-conformance', conformance], [contextual, contextualReview]]) {
  if (res && res.findings) for (const f of res.findings) {
    const tagged = { ...f, gate: g }
    allFindings.push(tagged)
    if (f.criterion_match && f.criterion_match !== 'none') criterionFindings.push(tagged)
  }
}

log(`gate complete: review=${review?.verdict} conformance=${conformance?.verdict}` +
    (contextual ? ` ${contextual}=${contextualReview?.verdict}` : '') +
    ` | ${allFindings.length} finding(s), ${criterionFindings.length} criterion-matched (surface-worthy)`)

return {
  track: 'nimble',                                 // explicit track => persist routes deterministically
  exploreMap,
  implementation: payload.implementation,          // report STRING (persist contract unchanged)
  integrate,                                        // structured integrate result (ADR-046)
  review, conformance,
  contextualReview: contextualReview || null,
  contextualType: contextual,                      // CR-001: lets the orchestrator name the findings file
  modelRouting: payload.modelRouting,              // ADR-102: build-role tier audit (rides the persist payload)
  integrateIsolation: payload.integrateIsolation,  // SHR3-T3/ADR-046: launching-context isolation audit (no new write path)
  allFindings, criterionFindings,
  surfaceRequired: criterionFindings.length > 0,   // advisory: orchestrator disposes judgment-class, halts only on execution-block (ADR-105)
}
