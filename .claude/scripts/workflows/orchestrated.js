export const meta = {
  name: 'orchestrated',
  description: 'v2 orchestrated preset (ADR-062/ADR-063): cto -> architect-pre(writes ADR) -> pm-spec -> [ui-spec] -> [decompose] -> explore -> one implementer per wave (sequential in-context build, in-place on the wave branch) -> integrate (verification no-op) -> batch-gate (D5) -> [architect-final (cross-wave seam only)]. Returns a structured payload the orchestrator persists (persist-run-artifacts.py) + commits. Honours the four ADR-039 engine contracts.',
  phases: [
    { title: 'cto', detail: 'cto-advisor evaluates the approach (GO gate)' },
    { title: 'architect-pre', detail: 'architect-review writes the ADR + validates the approach is sound' },
    { title: 'spec', detail: 'pm-spec captures requirements + acceptance criteria' },
    { title: 'ui-spec', detail: '[if UI] ui-spec produces the visual requirements addendum' },
    { title: 'decompose', detail: '[if multi-ticket] spec-decomposer emits tickets[] (key/deps/planned_files/acceptance AC-NNN)' },
    { title: 'explore', detail: 'Explore agents validate codebase assumptions' },
    { title: 'implement', detail: 'one implementer per wave (sequential in-context build) — single dispatch, in-place on the wave branch, commits per ticket' },
    { title: 'integrate', detail: 'verification no-op: assert per-ticket commits land in dependency order on the wave branch' },
    { title: 'gate', detail: 'batch-gate over the integrated diff: code-reviewer + spec-conformance + contextual(s) (D5)' },
    { title: 'architect-final', detail: 'architect-review validates a cross-wave composition (conditional on crossWavePrior)' },
  ],
}

// ===========================================================================
// THE v2 ORCHESTRATED ENGINE (ADR-062 doctrine; ADR-063 implementation).
//
// One Workflow call drives the chain: cto → architect-pre → pm-spec → [ui-spec] →
// [decompose] → explore → ONE implementer per wave (sequential in-context build,
// commits per ticket in-place on the wave branch) → integrate (verification no-op:
// assert one commit per ticket key in dep order via git log) → batch-gate → [architect-final
// only when composing with prior built waves: crossWavePrior:true].
//
// THE FOUR STANDARDIZED ENGINE CONTRACTS (ADR-039), preserved:
//  1. Defensive args parse — `args` may arrive as a JSON string.
//  2. Returns a structured payload; the ORCHESTRATOR persists artifacts
//     (persist-run-artifacts.py) — scripts have no FS access; read-only agents can't Write.
//     FS-less-relaxation (ADR-115 D5, carrying ADR-113 D2 — DECIDED, do NOT re-litigate): contract 2 is
//     REFINED, not relaxed — the SCRIPT performs no FS I/O; dispatched agents use the run folder as
//     intra-run handoff scratch BOUNDED to ${runDir} (specByPath() reads ${runDir}/spec.md), NEVER the
//     canonical docs/step-3-specs/**. The W2-specific relaxation record is ADR-115. The GENERAL code
//     mechanism that finalizes a forward-referenced ADR OUTSIDE the `if (!isPlanned)` preamble-skip on a
//     PLANNED build is W4's deliverable (the forward-referenced-ADR fall-through fix; ADR-116) — INSTALLED:
//     see the `payload.adrFinalize` SIGNAL placed after the preamble block (the engine signals; the skill
//     runs `claim-id.py adr` + the `Draft → Accepted` rewrite at build-start — ADR-116 D1 half-b).
//  3. The script COMPUTES the surface (criterionFindings + surfaceRequired, ADR-018 crit-1..5);
//     the ORCHESTRATOR performs the halt (consolidated surface, ADR-036) and the wave-level commit.
//  4. Isolation matches the preset: the wave-builder runs IN-PLACE on the wave branch (one sequential
//     writer per wave — no parallel-write hazard, no worktree to fan-in). Worktree isolation is preserved
//     for nimble's single-ticket dispatch (ADR-046); under ADR-062 it does NOT apply to orchestrated.
//
// HISTORICAL CONTEXT (superseded by ADR-062). Until ADR-062, this engine dispatched parallel-per-ticket
// implementers in worktrees with a staleness-guarded by-SHA fan-in merge; the within-wave parallel-write
// hazard required worktrees + a SHA-list shell-interpolation injection guard on integrate.
// ADR-062 §3 dissolves the within-wave shared-sink contention (one sequential writer); the worktree,
// the staleness guard inside the wave, the by-SHA fan-in, the false-disjoint detection, and the SHA-list
// injection guard all retire. Across-wave parallelism (independent waves) lives in `/launch` unchanged.
// The plan/wave/finalize phase modes + the rolling worker-pool, the Kahn dependency-wave partition, the
// concurrency cap, the per-wave-level cross-call seeding (the ADR-045/T16 dependency-wave loop) are
// retired here too — full audit trail in ADR-062 §Consequences and ADR-063.
//
// args: { runDir, repoRoot, task,
//         tickets?         : [{key,description,depends_on?,planned_files?,acceptance?,gates?}]  // skip decompose if given
//         waveSpecs?       : [{slug?,markdown}] | [string]  // PEC-T3 plan-detection: the on-disk wave-spec
//                             markdown the skill globbed; the engine classifies PLANNED iff EVERY entry
//                             parses to `## Tickets`/`### <KEY>:` blocks (with ingested tickets[] present)
//                             => skip the advisory preamble + decompose (slice-once). FS-less: content
//                             arrives via args (ADR-039 contract 2); the skill owns the glob.
//         specMarkdown?    : string  // optional: the PLANNED spec narrative for the gates' specByPath()
//                             (when the preamble's pm-spec is skipped); falls back to `task` if absent.
//         decompose?       : bool   (default true; false => single ticket = whole task)
//         ui?              : bool   (default false; true => run ui-spec)
//         contextual?      : string|string[]  // extra gate reviewers by file-type (D5)
//         crossWavePrior?  : bool   (default false; true => architect-final fires — the /orchestrate-epic
//                                    interleave case, ADR-059, composing this wave with prior built waves)
//         baseSha?         : string // wave-branch tip SHA captured by the orchestrator at dispatch
//                                    (`git rev-parse HEAD`). Embedded as an UNCONDITIONAL STEP 0 in the
//                                    wave-build brief (`git fetch . && git reset --hard <baseSha>`) so the
//                                    single in-place wave-builder starts from the deterministic dispatch-time
//                                    tip, not stale session-start state (ADR-085 D2). Absent => fall back to
//                                    the existing protocol-guard language. SHA arrives via args ONLY —
//                                    scripts have no git/FS access (ADR-039 contract 2).
//       }
//
// DELTA-AS-NEW-WAVE (VPH-W1C / ADR-114 D3). A delta on an already-roadmapped+built spec is handled by
// APPENDING it as a NEW `# Wave:` to the existing docs/step-3-specs/<slug>/ spec (a new waves/<wave-slug>/
// folder, authored via /roadmap and graduated through VPH-W1B's same merge-into-existing door), then
// building it like any subsequent wave. It REUSES the existing per-wave re-root: the orchestrator passes
// the prior built wave's integrated tip as `baseSha` (the same wave-stepping that re-roots wave i+1 off
// wave i's `integrated_head` — see STEP 0 at ~L1082), so the delta wave composes on the BUILT spec, not a
// stale base. No new engine path: the delta wave is just another wave through the unchanged build flow.
// OUT OF SCOPE (deferred): TRUE LINE-LEVEL INCREMENTAL REBUILD (re-running only changed lines/files of an
// already-built wave) — a heavier path, explicitly NOT built here (ADR-114 §Out of scope). W1C is
// delta-as-new-wave append only.
// ===========================================================================

const _a = typeof args === 'string' ? JSON.parse(args) : (args || {})        // contract 1
const { runDir, repoRoot, task } = _a
if (!runDir || !repoRoot || !task) {
  throw new Error(`orchestrated: missing required args (runDir/repoRoot/task). Got keys: ${Object.keys(_a).join(',') || '<none>'}`)
}
const wantDecompose = _a.decompose !== false
// ADR-104: the [ui-spec] dispatch fires on operator-override OR persisted-carry OR the deterministic
// UI-surface floor. The floor is evaluated over `_a.tickets` (the pre-decomposed dispatch arg — DEFINED
// here) NOT the working `tickets` var (undefined until post-decompose; using it here would throw — the
// DEFECT-1 the roadmap flagged). A non-UI / ad-hoc-decompose wave with no `_a.tickets` falls back to the
// advisor `_a.hasUi` carry + the post-decompose ui-review gate-add below.
const wantUi = _a.ui === true || _a.hasUi === true || hasUiSurface(_a.tickets)
const crossWavePrior = _a.crossWavePrior === true
const baseSha = _a.baseSha || null
// Optional per-file byte-size map for the wave context-budget estimator (ADR-086 D2). Scripts have
// no FS access (ADR-039 contract 2), so the orchestrator/skill passes byte sizes here where it has
// them; absent => the estimator falls back to a per-file constant and says so in the WARN.
const fileBytes = (_a.fileBytes && typeof _a.fileBytes === 'object') ? _a.fileBytes : {}
let contextual = _a.contextual || []
if (typeof contextual === 'string') contextual = [contextual]

// Ticket-key shape guard for the up-front graph validation (decompose). The v1 SHA/key shape-validation
// injection guards retired with the by-SHA fan-in shell interpolation (ADR-062 §3, T-103).
const KEY_SHAPE = /^[A-Za-z0-9._-]+$/

// --- D5: security-auditor auto-add on auth/secret/migration surfaces (ADR-018 crit-3) ---
const SENSITIVE = /\b(auth|authz|authn|secret|credential|token|password|migration|rls|\.sql)\b/i
function sensitiveText(s) { return typeof s === 'string' && SENSITIVE.test(s) }

// --- DETERMINISTIC, FAIL-CLOSED PLAN-DETECTION (ADR-112; PEC-T3/T4) -------------
// A spec FOLDER is PLANNED iff EVERY wave spec in it parses to >=1 `### <KEY>:` ticket block under a
// `## Tickets` heading — exactly the on-disk render `renderWaveSchema` (roadmap.js) emits. The signal is
// the markdown shape, NOT a JSON tickets[] array and NOT adr.md presence (both DEAD alternatives —
// roadmaps mint the ADR at build, none on disk). PURE markdown parsing — NO LLM, NO agent() anywhere in
// this path (mirrors the fail-closed precedents validateTicketGraph + runIntentCapture). The engine has
// NO FS (ADR-039 contract 2): the orchestrator/skill globs the folder and passes each wave spec's raw
// markdown via `_a.waveSpecs` ([{slug?, markdown}] or [string]); this function classifies that content.
// FAIL CLOSED: absent/empty waveSpecs OR any single raw/partial wave (no `## Tickets`) => NOT-PLANNED, so
// the advisory preamble runs — building unplanned is the dangerous direction.
function parsesToTickets(md) {
  if (typeof md !== 'string' || !md) return false
  const h = md.match(/^##[ \t]+Tickets[ \t]*$/m)            // the `## Tickets` heading
  if (!h) return false
  const after = md.slice(h.index + h[0].length)
  // `### KEY: title` — KEY shape mirrors the wave schema (PEC-T3, SSM-T1): ^[A-Z][A-Z0-9]*-[A-Z0-9]+
  return /^###[ \t]+[A-Z][A-Z0-9]*-[A-Z0-9]+:/m.test(after)
}
function detectPlanned(waveSpecs) {
  if (!Array.isArray(waveSpecs) || waveSpecs.length === 0) return false   // fail closed
  return waveSpecs.every(w => parsesToTickets(typeof w === 'string' ? w : (w && w.markdown)))
}
// PLANNED only when EVERY passed wave spec parses AND the orchestrator ingested the parsed tickets[]
// (the slice the roadmap already produced). Skip the preamble + decompose ONLY when there is a parsed
// plan to build. Operator-supplied tickets WITHOUT waveSpecs stay NOT-PLANNED — today's hand-fed path
// keeps its cto/architect/pm-spec pass (the safe direction).
// ADR-115 D3 (AC-013): detectPlanned() runs the SINGLE shape classification (parsesToTickets() once per
// wave spec) — there is NO redundant additional re-parse of the full markdown beyond it to remove, so
// AC-013 reduces to "preserve isPlanned + fail-closed." Do NOT add a second round-trip; the markdown is
// classified once here and is never re-parsed downstream. The fail-closed branch (absent/partial
// waveSpecs ⇒ NOT-PLANNED, in detectPlanned() above) is a SAFETY property — building unplanned is the
// dangerous direction. ADR-115 D2/AC-012: build/gate agents read the full spec narrative BY PATH via
// specByPath() (${runDir}/spec.md) + the in-engine acDigest; specMarkdown-by-value (L768) feeds ONLY the
// in-engine acDigest + this classification (the digest is the binding atom source, SA-001). ADR-115 D1
// (AC-011, the floor) and this direction (AC-012) are DECOUPLED — both hold regardless of the FS-less-
// relaxation outcome (AC-016); the wave is not blocked on it.
const isPlanned = detectPlanned(_a.waveSpecs) && Array.isArray(_a.tickets) && _a.tickets.length > 0

// --- BACK-END CROSS-WAVE DRIFT GATE (PEC-T6 / ADR-112 — MUST-PASS exit gate ii) ----------
// The plan-time partition check (roadmap.js validateWavePartition, PEC-T5) proves planned_files are
// disjoint across PARALLEL cross-wave tickets. This is its REALIZED-STATE mirror, run post-build: if two
// parallel cross-wave tickets (different wave_slug, no depends_on edge between them) actually WROTE the
// same file (a files_changed collision that was NOT in their disjoint planned_files), the wave-partition
// contract DRIFTED during the build — emit a crit-1 finding. Within-wave shared files are CORRECT (one
// sequential writer — ADR-062 §3) and are NEVER flagged. Pure analysis (no FS/agent); SILENT on a clean
// run (the silent half is as load-bearing as the fires half — a gate that always fires is useless).
function detectShippedSinkDrift(tickets, results) {
  const out = []
  const list = Array.isArray(tickets) ? tickets : []
  const byK = Object.fromEntries(list.map(t => [t.key, t]))
  const realized = {}
  for (const r of (Array.isArray(results) ? results : [])) {
    if (r && r.ticket_key) realized[r.ticket_key] = new Set(Array.isArray(r.files_changed) ? r.files_changed : [])
  }
  const reach = {}
  function cr(k, visiting) {
    if (reach[k]) return reach[k]
    if (visiting.has(k)) return new Set()
    visiting.add(k)
    const s = new Set()
    for (const d of ((byK[k] && byK[k].depends_on) || [])) { if (!byK[d]) continue; s.add(d); for (const x of cr(d, visiting)) s.add(x) }
    visiting.delete(k); reach[k] = s; return s
  }
  for (const t of list) cr(t.key, new Set())
  const dependsOn = (a, b) => !!(reach[a] && reach[a].has(b))
  const parallel = (a, b) => !dependsOn(a, b) && !dependsOn(b, a)
  for (let i = 0; i < list.length; i++) {
    for (let j = i + 1; j < list.length; j++) {
      const a = list[i], b = list[j]
      if (!a.wave_slug || !b.wave_slug || a.wave_slug === b.wave_slug) continue   // cross-wave only
      if (!parallel(a.key, b.key)) continue
      const fa = realized[a.key] || new Set()
      const shared = [...(realized[b.key] || new Set())].filter(f => fa.has(f))
      if (shared.length) out.push({
        gate: 'drift', id: `DRIFT-${a.key}-${b.key}`, severity: 'high',
        criterion_match: 'crit-1', recommended_disposition: 'ESCALATE',
        detail: `back-end drift: parallel cross-wave tickets '${a.key}' (${a.wave_slug}) and '${b.key}' ` +
          `(${b.wave_slug}) WROTE shared file(s) [${shared.join(', ')}] not in their disjoint planned_files — ` +
          `the wave-partition contract drifted during the build (ADR-048/ADR-062).`,
      })
    }
  }
  return out
}

// ---------------------------------------------------------------------------
// WAVE CONTEXT-BUDGET ESTIMATOR (ADR-086 D2) — deterministic, in-engine.
// Predicts the wave's implementer context consumption so an over-budget wave
// raises a WARN at PLANNING/run time (ADR-086 D4: WARN-and-surface, never a hard
// block). Constants are STARTING values; the T4.2 per-agent telemetry in
// measure-run.sh (ADR-086 D3) calibrates them from predicted-vs-actual peaks —
// they only need to be directionally right at the calibrated budget line. Identical copy lives
// in roadmap.js (scripts are self-contained; no cross-file imports — ADR-039).
const BUDGET_FACTORS = {
  READ_FACTOR: 3,               // planned files get read, re-read, and reasoned over (T4.2-calibrated)
  FIXED_OVERHEAD: 60_000,       // spec + findings + protocol + system prompt, per wave (tokens)
  EXPECTED_OUTPUT_PER_TICKET: 15_000,  // implementer write/think output per ticket (tokens)
  EFFECTIVE_TASK_CONTEXT: 80_000,  // ADR-086 D1 (Wave-1 landing zone): calibrated effective reasoning/code context ON TOP of FIXED_OVERHEAD; telemetry-tuned per D3
  PINNED_WINDOW: 1_000_000,     // Opus 4.8[1m] — context-window metadata (no longer drives the budget; see EFFECTIVE_TASK_CONTEXT)
  FALLBACK_FILE_BYTES: 8_192,   // per-file byte estimate when no byte data is supplied via args
}
// Estimate predicted implementer token consumption for a wave's tickets.
//   tickets   : [{ planned_files?: string[] }]
//   fileBytes : optional { "<path>": <bytes> } map (passed via args; scripts have no FS — ADR-039).
//               Absent/partial => FALLBACK_FILE_BYTES per file (the WARN text says so).
// Formula (ADR-086 D2): (planned_file_bytes / 4) * READ_FACTOR + FIXED_OVERHEAD
//                       + EXPECTED_OUTPUT_PER_TICKET * ticketCount.
function estimateWaveTokens(tickets, fileBytes) {
  const F = BUDGET_FACTORS
  const bytesMap = (fileBytes && typeof fileBytes === 'object') ? fileBytes : {}
  let totalBytes = 0
  let usedFallback = false
  let fileCount = 0
  const seen = new Set()
  for (const t of (tickets || [])) {
    for (const f of (t.planned_files || [])) {
      if (seen.has(f)) continue            // count a shared in-wave file once
      seen.add(f)
      fileCount++
      if (Object.prototype.hasOwnProperty.call(bytesMap, f) && Number.isFinite(bytesMap[f])) {
        totalBytes += Math.max(0, bytesMap[f])
      } else {
        totalBytes += F.FALLBACK_FILE_BYTES
        usedFallback = true
      }
    }
  }
  const ticketCount = Array.isArray(tickets) ? tickets.length : 0
  const readTokens = (totalBytes / 4) * F.READ_FACTOR
  const outputTokens = F.EXPECTED_OUTPUT_PER_TICKET * ticketCount
  const predicted = Math.round(readTokens + F.FIXED_OVERHEAD + outputTokens)
  const budget = F.FIXED_OVERHEAD + F.EFFECTIVE_TASK_CONTEXT   // ADR-086 D1: calibrated basis — overhead + effective task context (NOT fraction × window)
  return {
    predicted, budget,
    pct: budget ? Math.round((predicted / budget) * 1000) / 10 : 0,   // % of budget, 1 decimal
    over: predicted > budget,
    fileCount, ticketCount, totalBytes, usedFallback,
  }
}
// Build the human-readable WARN detail for an over-budget wave (ADR-086 D4).
function budgetWarnDetail(est) {
  const fallbackNote = est.usedFallback
    ? ` File byte sizes were not all supplied via args, so a ${BUDGET_FACTORS.FALLBACK_FILE_BYTES}-byte/file fallback ` +
      `was used for ${est.fileCount} file(s) — the prediction is coarse; pass per-file bytes for precision.`
    : ''
  return `WAVE CONTEXT BUDGET (ADR-086): predicted implementer consumption ~${est.predicted.toLocaleString()} tokens ` +
    `vs budget ${est.budget.toLocaleString()} (calibrated basis: FIXED_OVERHEAD ${BUDGET_FACTORS.FIXED_OVERHEAD.toLocaleString()} + ` +
    `~${BUDGET_FACTORS.EFFECTIVE_TASK_CONTEXT.toLocaleString()} effective task context — ADR-086 D1/D3, telemetry-calibrated) = ` +
    `${est.pct}% of budget. This wave (${est.ticketCount} ticket(s), ${est.fileCount} planned file(s)) is predicted to ` +
    `EXCEED the budget. ADR-086: consider splitting at a dependency seam (the slicer proposes the cut), or knowingly ` +
    `accept the over-budget wave — per-ticket commits + the thin manifest make the breach a recoverable, logged bet, ` +
    `not a mid-build re-plan.${fallbackNote}`
}

// ---------------------------------------------------------------------------
// DYNAMIC BUILD-ROLE MODEL TIER (ADR-102) — pure, deterministic, FS-free, inline.
// Picks the model tier for the BUILD ROLE ONLY (DP-1/R15): genuinely-cheap waves
// (docs-only diffs, trivial single-file/≤2-AC tickets) build on `sonnet`; everything
// else, and anything uncertain, builds on `opus`. The codomain is structurally
// EXACTLY {'sonnet','opus'} — never below the ADR-099 sonnet floor, never Fable: a
// buggy emit bricks to Opus (block-fable-dispatch.sh hard-BLOCKs `fable`), never
// overspends or downgrades dangerously. Mirrors estimateWaveTokens (self-contained,
// defensive, no FS, no cross-file imports — ADR-039); the docs-only guard mirrors the
// SENSITIVE/sensitiveText allowlist-predicate-over-planned_files shape. An identical
// single-task variant lives inline in nimble.js (intentional duplication — same
// constraint as the duplicated estimateWaveTokens; ADR-039 forbids the shared module).
const BUILD_TIER = { SONNET: 'sonnet', OPUS: 'opus' }   // the entire codomain (ADR-099 floor; no Fable per ADR-095)
// Cosmetic-only allowlist class — the SAME set as `manual_review_required` cosmetic-only
// in rules-orchestrated-mode.md (docs/, top-level *.md, tests/). Match is allowlist-POSITIVE
// (every entry must match) and NON-SPOOFABLE: normalize the path first, then reject any
// `../` or absolute escape into source before prefix-matching (AC-016).
// Normalize a path purely (no FS): collapse `./`, resolve `..`. Returns { norm, suspicious } where
// `suspicious` is true for an absolute path or a `..` escape above the repo root — a crafted entry that
// must NEVER route sonnet (it poisons BOTH the docs-only guard AND the trivial branch → forces Opus).
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
// True iff a single planned_files entry is in the cosmetic-only allowlist class (docs/, top-level *.md,
// tests/) AFTER normalization, with no `..`/absolute escape. Allowlist-POSITIVE, non-spoofable (AC-016).
function isCosmeticOnlyPath(p) {
  const { norm, suspicious } = normalizePlannedPath(p)
  if (suspicious || !norm) return false          // absolute / ..-escape / empty — NOT cosmetic
  const parts = norm.split('/')
  if (norm === 'docs' || norm.startsWith('docs/')) return true     // docs/**
  if (norm === 'tests' || norm.startsWith('tests/')) return true   // tests/**
  if (parts.length === 1 && /\.md$/i.test(norm)) return true       // top-level *.md
  return false
}
// True iff ANY planned_files entry across the wave is a suspicious (escape/absolute) path — such an entry
// poisons the trivial branch so a crafted single-file escape can never sneak onto sonnet (AC-016).
function waveHasSuspiciousPath(tickets) {
  for (const t of (Array.isArray(tickets) ? tickets : [])) {
    const pf = t && t.planned_files
    if (Array.isArray(pf)) for (const f of pf) if (normalizePlannedPath(f).suspicious) return true
  }
  return false
}
// True iff EVERY planned_files entry across the WHOLE wave is cosmetic-only AND there is
// at least one file. Empty/absent planned_files is NOT docs-only (it is uncertain → Opus).
function isDocsOnlyWave(tickets) {
  if (!Array.isArray(tickets) || tickets.length === 0) return false
  let sawAnyFile = false
  for (const t of tickets) {
    const pf = t && t.planned_files
    if (!Array.isArray(pf)) return false          // malformed/absent metadata → not docs-only (→ Opus)
    for (const f of pf) {
      sawAnyFile = true
      if (!isCosmeticOnlyPath(f)) return false     // a single non-cosmetic entry forces the later branch
    }
  }
  return sawAnyFile                                // false when no files were planned at all (empty wave)
}
// True iff a single planned_files entry is a UI surface AFTER normalization (no `..`/absolute escape).
// UI surface = a visual file extension OR a conventional UI directory segment. Reuses normalizePlannedPath
// EXACTLY like the docs-only/trivial classifiers (AC-002/AC-016) so a `../`-escape or absolute entry does
// NOT flag UI (non-spoofable).
function isUiSurfacePath(p) {
  const { norm, suspicious } = normalizePlannedPath(p)
  if (suspicious || !norm) return false
  if (/\.(tsx|jsx|vue|svelte|css|scss)$/i.test(norm)) return true        // visual file extensions
  // Case-insensitive segment match (SA-INFO-1): mirrors the case-insensitive extension test so a
  // PascalCase UI dir (e.g. `Components/`) still flags — under-detection here = a silently-skipped gate.
  return norm.split('/').some(seg => ['components', 'app', 'pages', 'ui'].includes(seg.toLowerCase()))
}
// hasUiSurface(tickets) — the deterministic UI-surface floor (ADR-104). True iff ANY planned_files entry
// across the wave is a UI surface. Drives BOTH the [ui-spec] dispatch (over `_a.tickets`, pre-decompose —
// the arg is defined; the working `tickets` is not until post-decompose) AND the ui-review gate auto-add
// (over the decomposed `tickets`, post-decompose). O(files), ZERO new agent dispatches — same cost class as
// isDocsOnlyWave (AC-019); mirrors waveHasSuspiciousPath's iteration shape.
function hasUiSurface(tickets) {
  for (const t of (Array.isArray(tickets) ? tickets : [])) {
    const pf = t && t.planned_files
    if (Array.isArray(pf)) for (const f of pf) if (isUiSurfacePath(f)) return true
  }
  return false
}
// computeBuildTier(tickets) -> 'sonnet' | 'opus'. First-match-wins, in this exact order:
//   1. docs-only  → sonnet  (every planned file cosmetic-only; AC-002/AC-016)
//   2. trivial    → sonnet  (aggregate planned_files ≤1 AND union AC ≤2; AC-003)
//   3. else       → opus    (default; AC-004 default-to-Opus-when-uncertain)
// Codomain clamp (AC-010): the final return is structurally constrained to {sonnet,opus};
// any non-sonnet internal value clamps to opus. Never throws on malformed input.
function computeBuildTier(tickets) {
  // Defensive: anything that isn't a non-empty ticket array is uncertain → Opus.
  if (!Array.isArray(tickets) || tickets.length === 0) return BUILD_TIER.OPUS
  // (1) docs-only guard
  if (isDocsOnlyWave(tickets)) return BUILD_TIER.SONNET
  // A crafted escape/absolute planned_files entry poisons every cheap branch → Opus (AC-016): it fails
  // the docs-only allowlist above AND must not slip onto sonnet via the trivial single-file branch.
  if (waveHasSuspiciousPath(tickets)) return BUILD_TIER.OPUS
  // (2) trivial guard — aggregate distinct planned_files ≤1 AND union AC ≤2.
  const files = new Set()
  const acs = new Set()
  let metadataOk = true
  for (const t of tickets) {
    const pf = t && t.planned_files
    const ac = t && t.acceptance
    if (pf !== undefined && !Array.isArray(pf)) metadataOk = false   // non-array → malformed → Opus
    if (ac !== undefined && !Array.isArray(ac)) metadataOk = false
    if (Array.isArray(pf)) for (const f of pf) if (typeof f === 'string' && f) files.add(f)
    if (Array.isArray(ac)) for (const a of ac) if (typeof a === 'string' && a) acs.add(a)
  }
  if (metadataOk && files.size <= 1 && acs.size <= 2) {
    // Empty/absent planned_files (files.size === 0) is uncertain, NOT trivial → fall through to Opus.
    if (files.size >= 1) return BUILD_TIER.SONNET
  }
  // (3) default + codomain clamp: anything reaching here is Opus, and any stray non-sonnet
  // value is clamped to Opus (load-bearing — the only failure mode is "ran Opus", never Fable).
  return BUILD_TIER.OPUS
}
// Assemble the always-logged MODEL TIER rationale + the modelRouting audit record (AC-008/AC-009).
// fileCount/acCount/docsOnly describe the wave the tier was computed from.
function buildModelRouting(tickets) {
  const tier = computeBuildTier(tickets)
  const files = new Set()
  const acs = new Set()
  for (const t of (Array.isArray(tickets) ? tickets : [])) {
    if (t && Array.isArray(t.planned_files)) for (const f of t.planned_files) if (typeof f === 'string' && f) files.add(f)
    if (t && Array.isArray(t.acceptance)) for (const a of t.acceptance) if (typeof a === 'string' && a) acs.add(a)
  }
  const fileCount = files.size
  const acCount = acs.size
  const docsOnly = isDocsOnlyWave(tickets)
  let rule
  if (tier === BUILD_TIER.SONNET && docsOnly) rule = `docs-only diff (${fileCount} file${fileCount === 1 ? '' : 's'}, all cosmetic docs/**·*.md·tests/**)`
  else if (tier === BUILD_TIER.SONNET) rule = `trivial (${fileCount} file${fileCount === 1 ? '' : 's'}, ${acCount} AC)`
  else rule = `default (${fileCount} file${fileCount === 1 ? '' : 's'}, ${acCount} AC)`
  return { tier, rule, fileCount, acCount, docsOnly }
}

// ---------------------------------------------------------------------------
// PER-DISPATCH TOKEN-BUDGET CIRCUIT BREAKER (ADR-102 / W3DMR-T5) — AUTO-PAUSE, NEVER AUTO-KILL.
// On a dispatch whose observed output-token usage exceeds its per-class budget, the breaker AUTO-PAUSEs
// and SURFACEs (pushes a criterionFindings ESCALATE entry — the orchestrator performs the halt, ADR-039
// contract 3 / ADR-018/036). It NEVER aborts/kills the dispatch: a truncated build is worse than an
// expensive one, and a hard cap removes operator control (mirrors ADR-088 D4 "no hard cap in v1"). The
// dispatch result is ALWAYS preserved; the breaker only flags.
//
// METRICS ACCESS (AC-013): the per-class budgets below are STARTING CONSTANTS derived from the W1.5
// `_metrics.jsonl` telemetry (ADR-100) — directionally-right like BUDGET_FACTORS, calibrated later off
// more samples. The engine has NO FS access (ADR-039 contract 2), so the budgets are baked from the
// telemetry at authoring time rather than read live; any future write to _metrics.jsonl rides the EXISTING
// atomic-append contract in persist-run-artifacts.py — there is NO bespoke open(...,'a')/fs.appendFile on
// _metrics.jsonl anywhere in this engine (read-only consumer).
//
// CHOSEN PERCENTILE (documented inline, per ADR-086/D4 convention): the budget is seeded at ~2× the
// observed per-subagent OUTPUT-token mean from the first W1.5 attribution row (subagent_output_tokens
// 514,949 across subagent_count 38 ≈ ~13,550 output tokens/subagent mean). 2× the mean is the
// directionally-right p95-ish breach line — a dispatch emitting >~27k output tokens is a runaway-shaped
// outlier worth a PAUSE-and-look, not a kill. Reviewer/advisor dispatches are tighter (they emit verdicts,
// not builds). These are STARTING values; W4's gate-efficacy ledger recalibrates them.
const DISPATCH_BUDGETS = {
  // per-class OUTPUT-token soft ceiling (a breach => AUTO-PAUSE + ESCALATE, never kill)
  implementer: 27_000,   // ~2× the W1.5 per-subagent output mean (≈13.55k); builders legitimately emit more
  advisor:     12_000,   // cto/architect/pm-spec/ui-spec — verdicts + spec prose, tighter than a builder
  reviewer:    12_000,   // code-reviewer/spec-conformance/security-auditor — findings, not artifacts
}
// Map an agentType to its budget class. Unknown types fail-OPEN (no budget → never breaches → never
// PAUSEs spuriously); the breaker only ever ADDS a surface, so an over-permissive map cannot brick a run.
function dispatchBudgetClass(agentType) {
  if (agentType === 'implementer') return 'implementer'
  if (agentType === 'cto-advisor' || agentType === 'architect-review' || agentType === 'pm-spec' || agentType === 'ui-spec') return 'advisor'
  if (agentType === 'code-reviewer' || agentType === 'spec-conformance' || agentType === 'security-auditor' ||
      agentType === 'performance-reviewer' || agentType === 'accessibility-auditor' || agentType === 'db-migration-reviewer') return 'reviewer'
  return null
}
// Check a completed dispatch's observed token usage against its per-class budget. On breach, push an
// ESCALATE criterionFindings entry (PAUSE-and-surface). `observedTokens` is the dispatch's output-token
// count if the runtime surfaces it (usage block); ABSENT/non-finite => fail-open (no check, no PAUSE).
// Returns true iff a breach was surfaced (purely for logging/tests; the dispatch result is untouched).
function checkDispatchBudget(label, agentType, observedTokens) {
  const cls = dispatchBudgetClass(agentType)
  if (!cls) return false                                            // unknown class → fail-open, no PAUSE
  if (!Number.isFinite(observedTokens)) return false               // no usage data → fail-open, no PAUSE
  const budget = DISPATCH_BUDGETS[cls]
  if (observedTokens <= budget) return false                       // within budget → no action
  // BREACH → AUTO-PAUSE + SURFACE. Push an ESCALATE finding; the orchestrator halts (never auto-kills).
  criterionFindings.push({
    gate: `budget-breaker:${label}`, id: `BUDGET-${label}`,
    severity: 'high', criterion_match: 'crit-4',                   // operator-authority: the operator decides to continue/stop
    recommended_disposition: 'ESCALATE',
    detail: `Token-budget breaker (ADR-102 T5): the '${label}' dispatch (class ${cls}) emitted ~${observedTokens.toLocaleString()} ` +
      `output tokens, over its ~${budget.toLocaleString()}-token soft budget (W1.5-derived starting constant). ` +
      `AUTO-PAUSED and surfaced for operator review — the dispatch was NOT killed/aborted (a truncated build is worse ` +
      `than an expensive one; ADR-088 D4 parity). The dispatch result is preserved. Continue, split, or stop is the ` +
      `operator's call. Budget constants are directionally-right starting values, calibrated later (W4 ledger).`,
  })
  log(`budget-breaker: ${label} (${cls}) emitted ~${observedTokens.toLocaleString()} > ~${budget.toLocaleString()} — AUTO-PAUSE + ESCALATE (never killed)`)
  return true
}

// ---------------------------------------------------------------------------
// Schemas (schema-forced structured output => mechanical surface logic, not prose-parsing)
// ---------------------------------------------------------------------------
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
// AMS-T7 (ADR-099 Mechanism B): the wave-start recall dispatch returns the framed recalled block (or
// "" when disabled/empty/failed — fail-open). The engine assigns it to payload.recalledFacts; the
// orchestrator persists recalled-facts.md (ADR-039 contract 2 — script returns, orchestrator persists).
const RECALL_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['recalledFacts'],
  properties: { recalledFacts: { type: 'string' } },   // FRAME_PREFIX-framed, byte-capped block, or ''
}
const CTO_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['recommendation', 'rationale'],
  properties: {
    recommendation: { type: 'string', enum: ['GO', 'SIMPLIFY', 'DEFER', 'NO-GO'] },
    rationale: { type: 'string' },
    evaluation_markdown: { type: 'string' },
  },
}
const ARCH_PRE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['verdict', 'adr_markdown'],
  properties: {
    verdict: { type: 'string', enum: ['SOUND', 'REQUEST_CHANGES'] },
    summary: { type: 'string' },
    adr_markdown: { type: 'string' },          // the ADR the pre-pass authors; orchestrator persists adr.md
  },
}
const SPEC_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['spec_markdown'],
  properties: { spec_markdown: { type: 'string' }, summary: { type: 'string' } },
}
// PEC-T14: examiner fold-in verdict over the build-bound spec (Fable seat, ADR-088/095/099 — NOT re-authored).
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
const UISPEC_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['ui_spec_markdown'],
  properties: { ui_spec_markdown: { type: 'string' }, summary: { type: 'string' } },
}
// Canonical ticket schema (ADR-044). `acceptance[]` carries the AC-NNN atom IDs
// the ticket claims — additive to the existing atom machinery (pm-spec mints
// AC-NNN in spec.md; the union of all tickets' acceptance[] is the coverage set).
// `depends_on` is ticket-KEY strings (already shipped). `gates` is optional
// contextual reviewers (D5).
const TICKETS_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['tickets'],
  properties: {
    tickets: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false,
        required: ['key', 'description', 'depends_on', 'planned_files', 'acceptance'],
        properties: {
          key: { type: 'string' },
          description: { type: 'string' },
          depends_on: { type: 'array', items: { type: 'string' } },     // ticket keys
          planned_files: { type: 'array', items: { type: 'string' } },
          acceptance: { type: 'array', items: { type: 'string' } },     // AC-NNN atom IDs this ticket claims (ADR-044)
          gates: { type: 'array', items: { type: 'string' } },          // optional contextual gate reviewers (D5)
          coupling_hint: { type: 'string', enum: ['high', 'low'] },     // optional; "high" => wave planner won't parallelize (ADR-048)
        },
      },
    },
  },
}
// Per-ticket implement result. Preserved for nimble's single-ticket path (backward compat) and used
// inside WAVE_BUILD_SCHEMA.tickets_built[] as the per-ticket record reported by the single wave-builder.
const IMPLEMENT_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['ticket_key', 'status', 'sha', 'report'],
  properties: {
    ticket_key: { type: 'string' },
    status: { type: 'string', enum: ['complete', 'refused', 'blocked'] },
    sha: { type: 'string' },                    // commit sha on the wave branch ('' if the ticket did not commit)
    files_changed: { type: 'array', items: { type: 'string' } },
    report: { type: 'string' },                 // COMPLETION_REPORT or REFUSAL rationale
  },
}
// ADR-062/063 one-implementer-per-wave: the wave-builder is a SINGLE implementer dispatch that builds
// every wave ticket sequentially in one in-place context on the wave branch and reports per-ticket via
// tickets_built[] (one IMPLEMENT_SCHEMA entry per ticket). wave_status summarises the whole wave.
const WAVE_BUILD_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['wave_status', 'tickets_built', 'wave_report'],
  properties: {
    wave_status: { type: 'string', enum: ['complete', 'blocked', 'refused'] },
    tickets_built: {
      type: 'array',
      items: IMPLEMENT_SCHEMA,                   // one per ticket built (in dependency order)
    },
    wave_report: { type: 'string' },             // wave-level COMPLETION_REPORT / REFUSAL rationale
  },
}
const INTEGRATE_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['status', 'integrated_head', 'merged', 'stale', 'report'],
  properties: {
    status: { type: 'string', enum: ['integrated', 'stale_refused', 'conflict', 'noop'] },
    integrated_head: { type: 'string' },
    base_sha: { type: 'string' },                             // CR-005: the pre-merge base (stable diff base)
    merged: { type: 'array', items: { type: 'string' } },     // ticket keys merged
    stale: { type: 'array', items: { type: 'string' } },      // ticket keys refused as stale
    conflict_files: { type: 'array', items: { type: 'string' } },  // on status=conflict: the files that conflicted (ADR-048)
    conflict_class: { type: 'string', enum: ['content-disjoint-append', 'overlapping-edit', 'other'] }, // ADR-048 surface class
    report: { type: 'string' },
  },
}
const ARCH_FINAL_SCHEMA = {
  type: 'object', additionalProperties: false,
  required: ['verdict', 'findings'],
  properties: {
    verdict: { type: 'string', enum: ['APPROVE', 'REQUEST_CHANGES'] },
    summary: { type: 'string' },
    findings: FINDINGS_SCHEMA.properties.findings,
  },
}

const CRIT = `For each finding set criterion_match per ADR-018 (none = auto-disposable; ` +
  `crit-1 architecture / crit-2 scope / crit-3 security / crit-4 operator-authority / crit-5 ambiguity) ` +
  `and recommended_disposition (APPLY/DEFER/DISMISS/ESCALATE).`

// --- AC digest (ADR-083 D1) ------------------------------------------------
// The spec's AC-NNN lines, deduped, joined — a deterministic, low-cost fallback embedded in the
// downstream dispatches that now read the full spec by path (${runDir}/spec.md, written by pm-spec).
// If pm-spec failed to write the file, the binding acceptance atoms still travel with the prompt.
// Same AC-NNN regex family as the in-script coverage check (operates on specText in memory).
function acDigest(spec) {
  if (typeof spec !== 'string' || !spec) return '(no AC-NNN atoms in spec)'
  const seen = new Set()
  const lines = []
  for (const line of spec.split('\n')) {
    if (/\bAC-\d+\b/.test(line)) {
      const t = line.trim()
      if (t && !seen.has(t)) { seen.add(t); lines.push(t) }
    }
  }
  return lines.length ? lines.join('\n') : '(no AC-NNN atoms in spec)'
}
// Shared spec-by-path preamble for read-by-path dispatches (ui-spec, explore, gates, architect-final).
// The AC digest is computed in-engine from in-memory specText — no agent can touch it. The on-disk
// file IS in the in-place wave-builder's write path (SA-001, T2 gate), so the atoms are BINDING and
// the file is supplementary narrative: a tampered spec.md cannot weaken what the gates check against.
function specByPath() {
  return `SPEC ACCEPTANCE ATOMS (binding — computed in-engine before implement; if the spec file ` +
    `conflicts with these, THESE win):\n${acDigest(specText)}\n` +
    `Full spec narrative: read ${runDir}/spec.md (written by pm-spec; supplementary context).`
}

// Accumulators for the structured return (orchestrator persists from these).
const criterionFindings = []
const allFindings = []
// WARN-class findings (ADR-086 D4): informational, ride the consolidated surface but NEVER force a
// halt. Pushed into allFindings (persisted + surfaced) but deliberately NOT into criterionFindings,
// so surfaceRequired (= criterionFindings.length > 0) is unaffected — "WARN-and-surface, never a hard
// block." Tagged kind:'WARN', criterion_match:'none' so any criterion-membership reader skips them.
const warnFindings = []
function warn(gate, id, detail) {
  const f = {
    gate, id, kind: 'WARN', severity: 'low',
    criterion_match: 'none', recommended_disposition: 'DISMISS', detail,
  }
  warnFindings.push(f)
  allFindings.push(f)
  log(`WARN [${gate}/${id}]: ${detail.slice(0, 200)}`)
}
// `payload` declared BEFORE the helpers that close over it (CR-006: avoids any TDZ hazard if a
// future maintainer adds an early-return path between the helpers and the first phase).
const payload = {}
payload.isPlanned = isPlanned                     // PEC-T3: deterministic plan-detection signal (persisted)
function harvest(gate, res) {
  if (res && Array.isArray(res.findings)) {
    for (const f of res.findings) {
      const tagged = { ...f, gate }
      allFindings.push(tagged)
      if (f.criterion_match && f.criterion_match !== 'none') criterionFindings.push(tagged)
    }
  }
}
// A short-circuit surface (e.g. cto NO-GO, arch-pre REQUEST_CHANGES) returns early with the payload
// built so far; the orchestrator persists what exists + surfaces. Never throws on a decision fork.
function shortCircuit(extra) {
  return {
    track: 'orchestrated',
    ...payload, ...extra,
    allFindings, criterionFindings, warnFindings,
    surfaceRequired: true,
  }
}

// Working set assigned by the preamble below: ticket list + the spec/ADR/explore context the
// single wave-builder needs at implement time.
let tickets, specText, archPre, exploreMap, gateReviewers

// ===========================================================================
// PREAMBLE: cto -> architect-pre -> pm-spec -> [ui] -> decompose -> graph-validate ->
// security-add -> explore.
// ===========================================================================

// --- cto-advisor (GO gate) -------------------------------------------------
// PEC-T4: the WHOLE advisory preamble (cto -> architect-pre -> pm-spec -> [ui-spec]) + decompose is
// SKIPPED on a PLANNED folder — slicing + advisory happened ONCE at plan time (/roadmap). A PLANNED run
// builds only (implement -> integrate -> gate). NO agent() for these phases on a PLANNED folder. The
// flow stays autonomous-to-completion (ADR-105/029/054) — detection feeds straight into build within one
// turn, with no operator gate inserted between plan and build.
let cto = null
if (!isPlanned) {
phase('cto')
cto = await agent(
  `cto-advisor: evaluate this orchestrated wave's approach BEFORE any spec/ADR/implementation. Repo: ${repoRoot}.\n\n` +
  `TASK:\n${task}\n\nReturn recommendation (GO/SIMPLIFY/DEFER/NO-GO) + rationale + an evaluation_markdown body.`,
  { label: 'cto-advisor', phase: 'cto', agentType: 'cto-advisor', schema: CTO_SCHEMA }
)
payload.cto = cto
if (!cto || cto.recommendation !== 'GO') {
  // Non-GO is a material decision (crit-2 scope / crit-1 architecture). Do NOT build what the CTO
  // gated. Surface with the verdict; the orchestrator presents SIMPLIFY/DEFER/NO-GO options.
  criterionFindings.push({
    gate: 'cto-advisor', id: 'CTO-GATE',
    severity: cto && cto.recommendation === 'SIMPLIFY' ? 'high' : 'critical',
    criterion_match: 'crit-2', recommended_disposition: 'ESCALATE',
    detail: `cto-advisor returned ${cto ? cto.recommendation : 'NULL'}: ${cto ? cto.rationale : 'agent died'}`,
  })
  log(`cto gate: ${cto ? cto.recommendation : 'NULL'} — short-circuit surface (not building a gated approach)`)
  return shortCircuit({ stoppedAt: 'cto' })
}
log(`cto gate: GO`)

// --- architect-review (PRE pass — writes the ADR; D4 pass 1 of 2) ----------
phase('architect-pre')
archPre = await agent(
  `architect-review (PRE-IMPLEMENTATION pass): validate this approach is architecturally sound and AUTHOR the ADR. ` +
  `Repo: ${repoRoot}. The CTO returned GO.\n\nTASK:\n${task}\n\nCTO rationale:\n${cto.rationale}\n\n` +
  `Return verdict (SOUND if the approach is sound to build; REQUEST_CHANGES if it needs rework before any spec) ` +
  `and adr_markdown — the full ADR (context/decision/alternatives/consequences) the implementer will build against.\n\n` +
  `BEFORE returning, also WRITE your full ADR markdown to ${runDir}/adr.md (you have a Write tool). ` +
  `architect-final (if it fires) reads the ADR by that path instead of re-embedding it; the orchestrator's ` +
  `post-run persist re-writes the same content idempotently (ADR-083 D1).`,
  { label: 'architect-review:pre', phase: 'architect-pre', agentType: 'architect-review', schema: ARCH_PRE_SCHEMA }
)
payload.archPre = archPre
if (!archPre || archPre.verdict !== 'SOUND') {
  criterionFindings.push({
    gate: 'architect-review:pre', id: 'ARCH-PRE',
    severity: 'critical', criterion_match: 'crit-1', recommended_disposition: 'ESCALATE',
    detail: `architect-review (pre) returned ${archPre ? archPre.verdict : 'NULL'}: ${archPre ? (archPre.summary || '') : 'agent died'}`,
  })
  log(`architect-pre: ${archPre ? archPre.verdict : 'NULL'} — short-circuit surface (approach not sound)`)
  return shortCircuit({ stoppedAt: 'architect-pre' })
}
log(`architect-pre: SOUND (ADR authored, ${(archPre.adr_markdown || '').length} chars)`)

// --- pm-spec ---------------------------------------------------------------
phase('spec')
const spec = await agent(
  `pm-spec: capture requirements + acceptance criteria for this wave. Repo: ${repoRoot}.\n\n` +
  `TASK:\n${task}\n\nADR (build against this):\n${archPre.adr_markdown}\n\n` +
  `Return spec_markdown — a structured spec with acceptance criteria, one section per logical unit of work.\n\n` +
  `BEFORE returning, also WRITE your full spec markdown to ${runDir}/spec.md (you have a Write tool). ` +
  `Downstream agents (ui-spec, explore, the gates) read the spec by that path to avoid re-embedding it; ` +
  `the orchestrator's post-run persist re-writes the same content idempotently (ADR-083 D1).`,
  { label: 'pm-spec', phase: 'spec', agentType: 'pm-spec', schema: SPEC_SCHEMA }
)
payload.spec = spec
specText = (spec && spec.spec_markdown) || task
}   // end PEC-T4 advisory preamble (cto/architect-pre/pm-spec) — skipped entirely on a PLANNED folder
// On a PLANNED folder the preamble (incl. pm-spec) is skipped; the gates read the spec narrative the
// skill passes via specMarkdown (the on-disk wave spec), falling back to the wave intent (`task`).
if (isPlanned) {
  specText = _a.specMarkdown || task
  log('plan-detection: PLANNED — skipped cto/architect-pre/pm-spec; building the roadmap-sliced tickets[] directly')
}

// --- ADR-finalize SIGNAL (VPH-W4A / ADR-116 D1 half-b) ---------------------------------------------
// THE FORWARD-REFERENCED-ADR FALL-THROUGH FIX. On a PLANNED build the whole preamble above (incl. the
// architect-pre pass that is the ONLY inline ADR author) is SKIPPED — so the ADR `/roadmap` staged as a
// Draft at `docs/step-3-specs/<epic>/adr.md` would never be finalized. This step is placed DELIBERATELY
// OUTSIDE the `if (!isPlanned) { … }` preamble block (after it closes at the specText assignment above) so
// it is REACHED on the PLANNED path. It does NOT un-skip the preamble (that would re-run cto/architect-pre/
// pm-spec on every PLANNED build and defeat slice-once — ADR-112; ADR-116 Catch). The engine is FS-less
// (ADR-039 contract 2) and cannot run `claim-id.py`, so it only SIGNALS the finalize intent in the return
// payload; the SKILL performs the executable `claim-id.py adr <slug>` + `Draft → Accepted` rewrite at
// build-start (orchestrated/SKILL.md — the wire-to-consumer atom, AC-026). Gated on `isPlanned` INDEPENDENTLY
// of the preamble-skip — on NOT-PLANNED, architect-pre authored the ADR inline so no finalize is needed.
payload.adrFinalize = isPlanned
  ? { needed: true, draftPath: `${runDir}/adr.md`,
      slug: (Array.isArray(_a.waveSpecs) && _a.waveSpecs[0] && _a.waveSpecs[0].slug) || _a.epicSlug || null }
  : { needed: false }
log(`adr-finalize: ${payload.adrFinalize.needed ? `signalled (PLANNED) — skill claims the number + marks Accepted at ${payload.adrFinalize.draftPath}` : 'not needed (NOT-PLANNED — architect-pre authored the ADR inline)'}`)

// --- PEC-T14: examiner fold-in over the build-bound spec (BEFORE the wave-build) -------------------
// The front-half mirror of the roadmap funnel-tail examine (PEC-T13): ONE examiner (Fable seat — reuse
// ADR-088/095/099 dispatch, NOT re-authored) reviews the spec this wave will build against; its findings
// are FOLDED INTO the spec by a pm-spec re-dispatch (the examiner is review-only — ADR-088 D2). FOLD-IN,
// NOT a gate (AC-033): no halt, NO new halt class — a severe (RETHINK) verdict rides the EXISTING
// findings/decision-log surface, folded best-effort. SKIP on a PLANNED folder: it was authored by
// /roadmap, whose funnel-tail already examined the spec (PEC-T13) — don't double-examine the same
// artifact (AC-032). LEDGER (ADR-088 D4): the engine has NO filesystem (ADR-039 contract 2), so it
// returns the dispatch in payload.examinerDispatches[]; the ORCHESTRATOR appends one _fable-spend.jsonl
// line per entry post-run (the /examine O_APPEND snippet — see core/skills/orchestrated/SKILL.md).
payload.examinerDispatches = []
if (!isPlanned) {
  phase('examine')
  const exam = await agent(
    `examiner: review the spec this orchestrated wave-build will consume (repo ${repoRoot}). Emit GOOD/BAD/UGLY, ` +
    `a verdict (SOUND | FOLD-IN-REQUIRED | RETHINK), and prescriptive F-NNN findings. Review-only — author nothing. ` +
    `This is a FOLD-IN pass: findings are folded into the spec before the build (no halt, no gate).\n\n` +
    `SPEC:\n${specText}`,
    { label: 'examine', phase: 'examine', agentType: 'examiner', schema: EXAMINE_SCHEMA }
  )
  if (exam) {
    payload.examinerDispatches.push({ target: `orchestrated:${runDir}`, verdict: exam.verdict, over_envelope: false })
    allFindings.push({
      gate: 'examine', id: `examine-${exam.verdict}`, kind: 'INFO', severity: 'low',
      criterion_match: 'none', recommended_disposition: 'DISMISS',     // fold-in only — never gates (AC-033)
      detail: `examiner ${exam.verdict}: ${exam.summary || ''} ${(exam.findings || []).map(f => `${f.id}:${f.prescription}`).join(' | ')}`.slice(0, 1000),
    })
    if (exam.verdict !== 'SOUND' && Array.isArray(exam.findings) && exam.findings.length) {
      const folded = await agent(
        `pm-spec: revise the spec by folding in these examiner findings (each 'F-NNN: prescription'). Fold the ` +
        `mechanically-clear ones directly; note judgment calls inline. Return the full revised \`spec_markdown\`.\n\n` +
        `SPEC:\n${specText}\n\nEXAMINER FINDINGS:\n- ${exam.findings.map(f => `${f.id}: ${f.prescription}`).join('\n- ')}`,
        { label: 'examine-fold', phase: 'examine', agentType: 'pm-spec', schema: SPEC_SCHEMA }
      )
      if (folded && folded.spec_markdown && folded.spec_markdown.trim()) specText = folded.spec_markdown
    }
    log(`examine: ${exam.verdict} (${(exam.findings || []).length} findings) — fold-in, no halt (AC-033)`)
  }
}

// --- ui-spec (optional) ----------------------------------------------------
let uiSpec = null
if (wantUi && !isPlanned) {
  phase('ui-spec')
  uiSpec = await agent(
    `ui-spec: translate the spec + ADR into concrete visual requirements. Repo: ${repoRoot}.\n\n` +
    `${specByPath()}\n\nReturn ui_spec_markdown — the UI Specification Addendum.`,
    { label: 'ui-spec', phase: 'ui-spec', agentType: 'ui-spec', schema: UISPEC_SCHEMA }
  )
}
payload.uiSpec = uiSpec

// --- spec-decomposer -> tickets[] (optional; single-ticket if not decomposing) ----
phase('decompose')
// tickets is hoisted (assigned below)
if (Array.isArray(_a.tickets) && _a.tickets.length) {
  tickets = _a.tickets.map(t => ({
    key: t.key, description: t.description || task,
    depends_on: t.depends_on || [], planned_files: t.planned_files || [],
    acceptance: t.acceptance || [], gates: t.gates || [],
    wave_slug: t.wave_slug || null,    // PEC-T6: preserve wave partition for the back-end cross-wave drift gate
  }))
  log(`decompose: using ${tickets.length} ${isPlanned ? 'roadmap-sliced (PLANNED)' : 'operator-supplied'} ticket(s) — spec-decomposer NOT dispatched (slice-once)`)
} else if (!isPlanned && wantDecompose) {
  // Slice-once (PEC-T4): spec-decomposer dispatches ONLY for a NOT-PLANNED, no-ingested-tickets spec
  // (a hand-fed unsliced spec). A PLANNED folder never reaches here — its tickets[] come from /roadmap.
  const decomp = await agent(
    `spec-decomposer: decompose this spec into self-contained tickets for parallel implementation. Repo: ${repoRoot}.\n\n` +
    `SPEC:\n${specText}\n\nEach ticket: a stable key (T-001, T-002, ...), a description, depends_on (KEYS of tickets it ` +
    `directly depends on; [] for a leaf), planned_files (the files it will create/modify), and acceptance (the ` +
    `AC-NNN atom IDs from the spec this ticket claims — every AC-NNN in the spec must be claimed by at least one ` +
    `ticket; ADR-044).\n` +
    `SHARED-SINK RULE (ADR-048, load-bearing): two tickets with NO depends_on edge between them MUST NOT name ` +
    `the same file in planned_files — a shared append sink (styles.css, a barrel index.ts, one migrations file) ` +
    `conflicts at integrate even when each ticket's content is disjoint. When two tickets share a file, ` +
    `SERIALIZE them with a depends_on edge (default, for append targets) or set coupling_hint:"high" (only for ` +
    `genuine co-edit). Slice per the doctrine in core/reference/ticket-slicing-doctrine.md. Return { tickets: [...] }.`,
    { label: 'spec-decomposer', phase: 'decompose', agentType: 'spec-decomposer', schema: TICKETS_SCHEMA }
  )
  tickets = (decomp && decomp.tickets) || []
  if (!tickets.length) tickets = [{ key: 'T-001', description: task, depends_on: [], planned_files: [], acceptance: [] }]
  log(`decompose: ${tickets.length} ticket(s)`)
} else {
  tickets = [{ key: 'T-001', description: task, depends_on: [], planned_files: [], acceptance: [] }]
  log(`decompose: skipped — single ticket (whole task)`)
}
payload.tickets = tickets
// Soft epic warning (ADR-045) — a wave this wide is epic-shaped; the operator likely wants roadmap -> waves
// (T10), one orchestrated run per wave sequenced across windows, rather than one giant wave. Warning only.
if (tickets.length > 12) {
  log(`NOTE: ${tickets.length} tickets — epic-shaped. Consider roadmap -> waves (T10): split into smaller ` +
      `orchestrated runs sequenced one per usage window. (concurrency=${CONCURRENCY === Infinity ? 'unbounded' : CONCURRENCY} caps width, not total size.)`)
}

// --- WAVE CONTEXT-BUDGET WARN (ADR-086 D2/D4 — T4a) ------------------------
// Deterministic estimate of this wave's implementer context consumption. Over budget => a WARN-class
// finding rides the consolidated surface (informational; never forces a halt). The slicer proposes the
// dependency-seam split at planning time; this run-time check is the backstop for a wave that arrives
// (operator-supplied or decomposed) already over the 60% line.
{
  const est = estimateWaveTokens(tickets, fileBytes)
  payload.budgetEstimate = est
  if (est.over) {
    warn('context-budget', 'WAVE-BUDGET', budgetWarnDetail(est))
  } else {
    log(`context-budget: OK — predicted ~${est.predicted.toLocaleString()} tokens (${est.pct}% of budget` +
        `${est.usedFallback ? ', coarse — file bytes not all supplied' : ''})`)
  }
}

// --- ATOM-CHAIN GUARD (ADR-086 / handoff T6) -------------------------------
// The AC coverage check downstream fires false "dropped scope" alarms when a ticket is HAND-FED with an
// empty acceptance[] while the spec mints AC-NNN atoms. Guard: warn loudly (never block — hand-feeding is
// legitimate; silent atom loss is not) so the operator sees the broken atom chain, not a phantom GAP.
{
  const specMintsACs = /\bAC-\d{3}\b/.test(specText || '')
  if (specMintsACs) {
    for (const t of tickets) {
      if (!Array.isArray(t.acceptance) || t.acceptance.length === 0) {
        warn('atom-chain', `ATOM-CHAIN-${t.key}`,
          `hand-fed ticket ${t.key} broke the atom chain — the spec mints AC-NNN atoms but this ticket carries ` +
          `none in acceptance[]; the coverage check will read a phantom dropped-scope GAP. See the spec-decomposer ` +
          `contract (every AC-NNN must be claimed by >=1 ticket; ADR-044/ADR-086 T6). Warn, not block.`)
      }
    }
  }
}

// Validate the tickets graph UP FRONT (CR-008/CR-011/CR-003) — cheap, and fail-fast BEFORE the
// expensive parallel implement, with the same checks run-manifest.py enforces at persist time
// (key shape, uniqueness, orphan deps) plus a cycle check the Python validator does not do.
{
  const seen = new Set()
  const ticketKeys = new Set(tickets.map(t => t.key))
  const graphErrors = []
  for (const t of tickets) {
    if (!KEY_SHAPE.test(t.key)) graphErrors.push(`invalid ticket key shape '${t.key}'`)
    if (seen.has(t.key)) graphErrors.push(`duplicate ticket key '${t.key}'`)
    seen.add(t.key)
    for (const d of (t.depends_on || [])) {
      if (!ticketKeys.has(d)) graphErrors.push(`ticket '${t.key}' depends_on unknown key '${d}'`)
    }
  }
  // cycle detection (DFS colouring)
  const byK = Object.fromEntries(tickets.map(t => [t.key, t]))
  const WHITE = 0, GREY = 1, BLACK = 2
  const colour = {}
  for (const t of tickets) colour[t.key] = WHITE
  function dfs(k) {
    if (!byK[k]) return false
    colour[k] = GREY
    for (const d of (byK[k].depends_on || [])) {
      if (!byK[d]) continue
      if (colour[d] === GREY) return true                 // back-edge => cycle
      if (colour[d] === WHITE && dfs(d)) return true
    }
    colour[k] = BLACK
    return false
  }
  for (const t of tickets) if (colour[t.key] === WHITE && dfs(t.key)) { graphErrors.push(`dependency cycle through '${t.key}'`); break }
  if (graphErrors.length) {
    for (const e of graphErrors) criterionFindings.push({
      gate: 'decompose', id: 'DECOMP-GRAPH', severity: 'high',
      criterion_match: 'crit-1', recommended_disposition: 'ESCALATE', detail: e,
    })
    log(`decompose: tickets graph invalid (${graphErrors.length}) — short-circuit surface`)
    return shortCircuit({ stoppedAt: 'decompose' })
  }
}

// security auto-add (D5): scan task + ticket planned_files for sensitive surfaces
const sensitive = sensitiveText(task) || sensitiveText(specText) ||
  tickets.some(t => (t.planned_files || []).some(sensitiveText) || sensitiveText(t.description))
gateReviewers = [...new Set(contextual)]
if (sensitive && !gateReviewers.includes('security-auditor')) {
  gateReviewers.push('security-auditor')
  log(`D5: sensitive surface detected -> security-auditor auto-added to the batch-gate`)
}
// ui-review auto-add (ADR-104): the deterministic UI-surface floor adds the visual GATE, exactly as the
// security-auditor auto-add above. `tickets` is populated here (post-decompose), so this covers BOTH the
// pre-decomposed and the decompose-path waves — the gate never silently drops on a UI wave. Guarded against
// double-add when ui-review is already in `contextual`. Fails SAFE: a false-positive add wastes a gate,
// never drops scope (AC-018). On this epic's own .js/.py/.md infra wave, uiSurface is false (dogfood AC-017).
const uiSurface = hasUiSurface(tickets)
if (uiSurface && !gateReviewers.includes('ui-review')) {
  gateReviewers.push('ui-review')
  log(`D5: UI surface detected -> ui-review auto-added to the batch-gate`)
}
payload.gateReviewers = gateReviewers

// --- per-wave recall seam (Mechanism B; ADR-090 Implementation Notes / ADR-098 / ADR-099) -------
// AMS-T7. ONE memory read per wave, here at the wave-start seam — after the L65 destructure and
// BEFORE phase('explore'), NEVER inside the per-ticket implement loop (which begins after L580). The
// recalled block is cached once to ${runDir}/recalled-facts.md (the orchestrator persists it from
// payload.recalledFacts — ADR-039 contract 2: script returns, orchestrator persists) so every
// downstream ticket/agent inherits it passively, at zero per-agent latency, OUTSIDE the orchestrator's
// per-turn ~34k window.
//
// CRITICAL (ADR-039 contract 2): the engine body has NO FS/subprocess access — it MUST NOT shell
// graphiti-read.py itself. The read is performed by a dedicated Explore-class agent() dispatch (agents
// have FS access); the agent runs the read and RETURNS the framed block, which the engine assigns to
// payload.recalledFacts. This mirrors how adr.md/spec.md reach the script (returned, then persisted).
//
// FULL COHERENCE ENVELOPE (reuses the established read path — no parallel transport invented):
//  - OFF BY DEFAULT: gated behind the `.claude/agent-memory/graphiti-read-enabled` flag convention
//    (mirrors core/hooks/session-start-graphiti-read.sh L19/L28). Flag absent => the agent reads NOTHING,
//    returns an empty block, and the wave runs identically to today (AC-004 / AC-015).
//  - ROUTED THROUGH core/scripts/graphiti-read.py: the agent shells the EXISTING script (which owns
//    fetch/scrub/cap/recency-Cypher/FRAME_PREFIX/fail-open-exit-0) — the seam does NOT re-implement
//    transport (AC-006 / AC-016).
//  - BYTE-CAPPED + FRAMED + METERED: `--max-bytes` (default 1200) + the FRAME_PREFIX "recalled — may be
//    stale, verify against source" framing + `--meter` (per-read telemetry to stderr — the input W4's
//    eval collects) (AC-006).
//  - FAIL-OPEN at every step: graphiti down / timeout / non-2xx / empty graph / cold-start => the agent
//    injects NOTHING and the wave proceeds normally; never breaks or blocks (AC-005). graphiti-read.py
//    always exits 0.
//  - BUDGET-GATED: the per-turn injected total is bounded by the W2-rebaselined ceiling read from
//    docs/step-3-specs/ambient-memory-surfaces/coherence-budget.md §4 (~680 tokens/turn). The constant is
//    NOT re-derived inline here — the default `--max-bytes 1200` cap (~165 tokens measured) sits well
//    under §4's ~680-token/turn ceiling; raising the cap/top-k or firing on more turns is what §4 gates
//    (AC-007). See coherence-budget.md §4 for the binding number.
//
// REMOVABILITY: this seam is a single self-contained dispatch with no shared state with T8's per-agent
// seams; the whole expanded-read machinery is off-by-default machinery the operator opts into.
phase('recall')
const recall = await agent(
  `Search breadth: minimal. Repo: ${repoRoot}. You are performing the WAVE-START memory recall (ADR-099 ` +
  `Mechanism B) for this orchestrated wave. Do EXACTLY this, fail-open at every step, and return ONLY the ` +
  `recalled block (or an empty string):\n\n` +
  `1. OFF-BY-DEFAULT GATE: check whether \`${repoRoot}/.claude/agent-memory/graphiti-read-enabled\` exists. ` +
  `If it does NOT exist, return an EMPTY string immediately and do nothing else — the operator has not opted ` +
  `in (mirrors core/hooks/session-start-graphiti-read.sh).\n` +
  `2. If enabled: derive the group_id (mirror session-start-graphiti-read.sh — use the graphiti_groups ` +
  `registry loader if available; on any failure return empty). Then shell the EXISTING read script under a ` +
  `hard timeout — do NOT re-implement any fetch/scrub/cap logic:\n` +
  `   \`python3 ${repoRoot}/core/scripts/graphiti-read.py --group-id <gid> --top-k 5 --max-bytes 1200 --meter\`\n` +
  `   graphiti-read.py owns the recency Cypher, the FRAME_PREFIX "recalled — may be stale, verify against ` +
  `source" framing, the byte cap, the --meter telemetry line, and always-exit-0 fail-open. Let its --meter ` +
  `line go to stderr (W4's eval collects it).\n` +
  `3. BUDGET GATE: the per-turn injected total is gated against the ~680 tokens/turn ceiling in ` +
  `${repoRoot}/docs/step-3-specs/ambient-memory-surfaces/coherence-budget.md §4 (do NOT re-derive it). The ` +
  `default --max-bytes 1200 cap (~165 tokens) is well under that ceiling — do not raise it.\n` +
  `4. FAIL-OPEN: graphiti down / timeout / non-2xx / empty graph / cold-start => return an EMPTY string. ` +
  `An empty graph is the EXPECTED cold-start state, NOT an error. Never raise, never block.\n\n` +
  `RETURN: { recalledFacts: <the byte-capped, FRAME_PREFIX-framed stdout block from graphiti-read.py, or "" ` +
  `if disabled/empty/failed> }.`,
  { label: 'recall', phase: 'recall', agentType: 'Explore', schema: RECALL_SCHEMA }
)
// Fail-open: a null/blank return injects nothing. The framed block (or '') is persisted to
// recalled-facts.md by the orchestrator and threaded into downstream agent prompts below.
payload.recalledFacts = (recall && typeof recall.recalledFacts === 'string') ? recall.recalledFacts : ''
log(`recall: wave-start memory read ${payload.recalledFacts ? `(${payload.recalledFacts.length} chars recalled)` : '(empty — disabled or cold-start; fail-open)'}`)
// Shared preamble that threads the recalled block into a downstream agent's prompt. Empty when the
// read was disabled/empty/failed — the agent then runs exactly as today (off-by-default invariant).
function recalledPreamble() {
  return payload.recalledFacts
    ? `RECALLED LONG-TERM MEMORY (Graphiti, wave-level — may be stale, VERIFY against source before relying on it):\n${payload.recalledFacts}\n\n`
    : ''
}

// --- explore ---------------------------------------------------------------
phase('explore')
exploreMap = (await parallel([
  () => agent(
    recalledPreamble() +
    `Search breadth: medium. Repo: ${repoRoot}. Validate codebase assumptions for this wave.\n\n${specByPath()}\n\n` +
    `Report data shapes, file conventions, and existing patterns every ticket's implementer must match. Conclusions only.`,
    { label: 'explore', phase: 'explore', agentType: 'Explore' }
  ),
])).filter(Boolean)
payload.exploreMap = exploreMap

// ===========================================================================
// IMPLEMENT + INTEGRATE — T-102 replaces the parallel-per-ticket implement loop with a single
// wave-builder dispatch; T-103 collapses integrate to a verification no-op. See below.
// ===========================================================================

// --- implement: ONE implementer per wave (ADR-062 §3 / ADR-063 §D1). In-place on the wave branch
// (no worktree isolation flag on this agent dispatch — the within-wave parallel-write hazard the worktree existed to guard
// against is gone with a single sequential writer). The wave-builder enumerates ALL wave tickets in
// dependency order and commits per ticket with message `T-NNN: <description>` so per-ticket history is
// preserved in `git log` and integrate verifies it. Returns a WAVE_BUILD_SCHEMA payload — a wrapper
// over IMPLEMENT_SCHEMA[] (the legacy single-ticket schema is preserved for nimble's compat path).
phase('implement')
const exploreJoined = exploreMap.join('\n\n')

// dependency-ordered key list (topological; ties by input order). Used both for the wave-builder's
// prompt (so the operator sees the sequence the implementer should follow) and for integrate's
// verification step (T-103).
const order = []
const byKey = Object.fromEntries(tickets.map(t => [t.key, t]))
const placed = new Set()
function place(k, seen) {
  if (placed.has(k)) return
  if (seen.has(k)) return            // cycle guard (decomposer validates acyclic; defensive)
  seen.add(k)
  for (const d of (byKey[k] ? byKey[k].depends_on : [])) if (byKey[d]) place(d, seen)
  if (!placed.has(k)) { placed.add(k); order.push(k) }
}
for (const t of tickets) place(t.key, new Set())
const orderedTickets = order.map(k => byKey[k])

// Per-ticket prompt block — the wave-builder reads this serialised list and works through it.
const ticketBlock = orderedTickets.map((t, i) => {
  const deps = (t.depends_on && t.depends_on.length) ? t.depends_on.join(', ') : '(none — leaf)'
  const pfs = (t.planned_files && t.planned_files.length) ? t.planned_files.join(', ') : '(none declared)'
  const acs = (t.acceptance && t.acceptance.length) ? t.acceptance.join(', ') : '(none)'
  return (
    `### Ticket ${i + 1}/${orderedTickets.length} — ${t.key}\n` +
    `- depends_on: ${deps}  (within-wave sequencing hint for you, the one writer — not a parallel-merge contract)\n` +
    `- planned_files: ${pfs}\n` +
    `- acceptance (AC-NNN claimed): ${acs}\n\n` +
    `${t.description || '(no description)'}\n`
  )
}).join('\n')

log(`implement: 1 implementer building ${orderedTickets.length} ticket(s) sequentially in-context (ADR-062 one-implementer-per-wave)`)
// STEP 0 (ADR-085 D2): pin the wave-builder's base to the orchestrator-captured dispatch-time tip. The
// wave-builder runs in-place on the wave branch (no worktree under ADR-062), but a stale checkout is the
// same failure class the worktree-base bug names — an unconditional reset to the args-supplied SHA makes
// the base deterministic with no ancestry reasoning. SHA arrives via args ONLY (ADR-039 contract 2).
const waveStep0 = (baseSha && /^[0-9a-f]{7,40}$/i.test(baseSha))
  ? `STEP 0 (unconditional, before any work): \`git fetch . && git reset --hard ${baseSha}\` — then verify ` +
    `\`git rev-parse HEAD\` matches ${baseSha}. The wave base is known to drift to stale session-start state; ` +
    `this reset pins you to the dispatch-time wave-branch tip. Do NOT skip it.\n\n`
  : `STEP 0 (before any work): confirm you are on the current wave branch at its tip. Run the base-check guard ` +
    `in your protocol (core/agents/_shared/implementer-protocol.md) and \`git reset --hard\` onto the wave-branch ` +
    `tip if your checkout is rooted behind it — a checkout can drift to stale session-start state.\n\n`
// AMS-T7: the wave-level recalled-facts block is inherited PASSIVELY via the run folder — the
// orchestrator has written ${runDir}/recalled-facts.md from payload.recalledFacts before the wave
// builds. The implementer does NOT initiate a read (it is deliberately memory-blind — AMS-T9); it MAY
// passively read the wave-level recalled-facts.md if present and treat it as "recalled — may be stale,
// verify". The pointer below is wave-level passive inheritance, not a per-implementer read seam.
const recalledPointer = payload.recalledFacts
  ? `WAVE-LEVEL RECALLED MEMORY (passive — do NOT initiate your own read): ${runDir}/recalled-facts.md ` +
    `holds durable facts recalled once at wave start. It MAY be stale — verify any load-bearing fact ` +
    `against the source. This is inherited context, not an instruction to read memory yourself.\n\n`
  : ''
// --- DYNAMIC BUILD-ROLE MODEL TIER (ADR-102 / W3DMR-T4) --------------------
// Compute the tier at the dispatch site (wire-to-consumer — computeBuildTier is CALLED here, not merely
// defined). Threaded as the additive `model:` key on THIS build-role options object ONLY (AC-005); the
// integrate dispatch + every advisor/reviewer dispatch stay unrouted (AC-007/AC-011). Always-logged: the
// MODEL TIER brief states the tier + the rule that fired (AC-008). The modelRouting audit rides the
// existing returned payload (AC-009 — no new write path). Codomain is {sonnet,opus} (ADR-099 floor; the
// block-fable-dispatch.sh ALLOW arm). Default-to-Opus on any uncertain/malformed metadata.
const modelRouting = buildModelRouting(tickets)
payload.modelRouting = modelRouting
const modelTierBrief = `MODEL TIER: ${modelRouting.tier} — ${modelRouting.rule}\n` +
  `(Build-role model tier, computed deterministically per ADR-102. This dispatch runs on '${modelRouting.tier}'. ` +
  `Tier is build-role-only; advisors, reviewers, and integrate stay Opus-pinned. Default-to-Opus on uncertainty.)\n\n`
log(`model-tier: build-role dispatch routed to '${modelRouting.tier}' — ${modelRouting.rule}`)
const waveBuild = await agent(
  modelTierBrief +
  waveStep0 +
  recalledPointer +
  `Build an ENTIRE orchestrated wave end-to-end, sequentially, in ONE in-place context on the current (wave) branch ` +
  `of repo ${repoRoot}. You are the SOLE writer for this wave (ADR-062 §3 — one implementer per wave); there is no ` +
  `worktree and no parallel sibling. Within-wave \`depends_on\` is a SEQUENCING HINT for you (the one writer), not a ` +
  `parallel-merge contract. Tickets within this wave may share \`planned_files\` — that is correct, not an error.\n\n` +
  `BUILD ORDER (dependency-topological; build them in this exact order):\n` +
  orderedTickets.map(t => `- ${t.key}`).join('\n') + `\n\n` +
  `TICKETS:\n${ticketBlock}\n` +
  `SPEC (the wave you are building):\n${specText}\n\n` +
  `EXPLORATION findings to honour:\n${exploreJoined}\n\n` +
  `PROCEDURE — for EACH ticket, in the build order above:\n` +
  `  1. Implement the ticket end-to-end (edit/create files, run focused verification).\n` +
  `  2. \`git add\` the files you touched for THIS ticket.\n` +
  `  3. \`git commit -m "<ticket-key>: <concise description>"\` — one commit per ticket on the wave branch ` +
  `(e.g. \`git commit -m "T-101: <short description>"\`). The commit message MUST start with the literal ticket key ` +
  `followed by ": " so integrate can verify the per-ticket history.\n` +
  `  4. Record your per-ticket result (key, status, the commit sha from \`git rev-parse HEAD\`, files_changed, a short ` +
  `report) and proceed to the next ticket.\n\n` +
  `If a ticket genuinely cannot be built (out of scope, missing prerequisite, scope shift): commit nothing for that ` +
  `ticket, return its entry with status='refused' (out of scope / requires a decision the operator must make) or ` +
  `status='blocked' (a prerequisite missing). Earlier completed tickets remain committed.\n\n` +
  `RETURN: wave_status ('complete' if every ticket completed; 'blocked' if any ticket blocked; 'refused' if any ticket ` +
  `refused), tickets_built[] (one IMPLEMENT_SCHEMA entry per ticket in the BUILD ORDER above; each entry: ticket_key, ` +
  `status, sha = the commit sha for that ticket from \`git rev-parse <sha>\` ('' if no commit), files_changed, report), ` +
  `and wave_report (a COMPLETION_REPORT for the whole wave or a REFUSAL rationale).`,
  { label: 'implement', phase: 'implement', agentType: 'implementer', model: modelRouting.tier, schema: WAVE_BUILD_SCHEMA }
)
payload.waveBuild = waveBuild
// PER-DISPATCH TOKEN-BUDGET BREAKER (T5): check the build dispatch's observed output-token usage against
// its per-class budget. The runtime surfaces usage on the result's `_usage`/`usage` block when available;
// absent => fail-open (no PAUSE). On breach: AUTO-PAUSE + ESCALATE (the dispatch result above is preserved
// — never killed/aborted). The check ADDS a surface only; it never mutates waveBuild.
{
  const u = waveBuild && (waveBuild._usage || waveBuild.usage)
  const observed = u && Number.isFinite(u.output_tokens) ? u.output_tokens
    : (waveBuild && Number.isFinite(waveBuild.output_tokens) ? waveBuild.output_tokens : NaN)
  checkDispatchBudget('implement', 'implementer', observed)
}

// Normalise per-ticket results into the legacy implementResults shape the rest of the pipeline (and
// persist-run-artifacts.py) consumes unchanged.
const implementResults = orderedTickets.map(t => {
  const got = (waveBuild && Array.isArray(waveBuild.tickets_built))
    ? waveBuild.tickets_built.find(x => x && x.ticket_key === t.key)
    : null
  return got || { ticket_key: t.key, status: 'blocked', sha: '', files_changed: [],
    report: waveBuild ? 'wave-builder did not report this ticket' : 'wave-builder died (null return)' }
})
payload.implementResults = implementResults

// A ticket fails if it didn't complete OR it reported complete with no usable commit sha
// (a complete+empty-sha would mean the wave-builder claimed completion without committing — integrate
// would then have nothing to verify for that key). Validate sha shape inline.
const SHA_SHAPE = /^[0-9a-f]{7,40}$/i
const failed = implementResults.filter(r =>
  r.status !== 'complete' || !r.sha || !SHA_SHAPE.test(String(r.sha).trim()))
if (failed.length || (waveBuild && waveBuild.wave_status !== 'complete')) {
  for (const r of failed) {
    let why = r.status !== 'complete' ? r.status
            : !r.sha ? 'complete-but-no-sha'
            : 'complete-but-malformed-sha'
    criterionFindings.push({
      gate: `implement:${r.ticket_key}`, id: `IMPL-${r.ticket_key}`,
      severity: 'high', criterion_match: r.status === 'refused' ? 'crit-2' : 'crit-1',
      recommended_disposition: 'ESCALATE',
      detail: `ticket ${r.ticket_key} ${why}: ${(r.report || '').slice(0, 400)}`,
    })
  }
  if (waveBuild && waveBuild.wave_status !== 'complete' && !criterionFindings.some(f => f.id === 'WAVE-BUILD')) {
    criterionFindings.push({
      gate: 'implement', id: 'WAVE-BUILD',
      severity: 'critical', criterion_match: waveBuild.wave_status === 'refused' ? 'crit-2' : 'crit-1',
      recommended_disposition: 'ESCALATE',
      detail: `wave_status=${waveBuild.wave_status}: ${(waveBuild.wave_report || '').slice(0, 400)}`,
    })
  }
  log(`implement: wave_status=${waveBuild ? waveBuild.wave_status : 'NULL'}, ${failed.length}/${tickets.length} ticket(s) failed — short-circuit surface (no integration of a failed wave)`)
  return shortCircuit({ stoppedAt: 'implement' })
}
log(`implement: wave complete — ${implementResults.length}/${tickets.length} ticket(s) committed in dependency order`)

// --- integrate: VERIFICATION NO-OP (ADR-062 §3 / ADR-063 §D3) ----
// With one sequential writer per wave (T-102), per-ticket commits are already on the wave branch in
// dependency order — there is nothing to merge. Integrate reads `git log waveBase..HEAD` and asserts
// one commit per ticket key in dependency order with the 'T-NNN: ' message-format prefix.
//
// Excised (ADR-048 amended, ADR-062 §3): the staleness guard inside the wave (no separate worktree
// branches to be stale against); the by-SHA fan-in merge loop and its shell interpolation; the
// SHA/key shape-validation injection guards on the merge list (safe to drop because the
// multi-SHA shell interpolation they guarded is gone — security-confirmed); and the false-disjoint
// shared-sink detection (within-wave shared planned_files is correct under one sequential writer,
// not an error). Cross-wave shared-sink contention (parallel waves via `/launch`) is preserved
// outside this engine.
phase('integrate')
const expectedKeys = order.slice()                                       // dependency-topological order
const integrate = await agent(
  `Verify the per-ticket commits of an orchestrated wave are on the CURRENT (wave) branch in dependency order. ` +
  `Run IN PLACE in the main working tree of repo ${repoRoot}. The wave-builder (one sequential writer per ADR-062) ` +
  `committed each ticket directly on this branch — there is NOTHING TO MERGE. This is a verification no-op.\n\n` +
  `PROCEDURE:\n` +
  `  1. Capture the wave base: \`waveBase=$(git merge-base HEAD HEAD@{u} 2>/dev/null || git rev-parse HEAD~${expectedKeys.length})\` ` +
  `(the orchestrator's per-wave starting point — fallback walks back over the expected per-ticket commit count).\n` +
  `  2. List the per-ticket commits SINCE the wave base, oldest-first: \`git log --reverse --format='%H %s' "$waveBase"..HEAD\`.\n` +
  `  3. ASSERT there is exactly one commit per expected ticket key, in this EXACT dependency order, with subject ` +
  `matching the literal prefix '<key>: ': ${expectedKeys.join(' -> ')}.\n` +
  `  4. If every assertion holds: return status='integrated', integrated_head=$(git rev-parse HEAD), ` +
  `merged=[${expectedKeys.map(k => `"${k}"`).join(', ')}] (the ticket keys verified — the legacy 'merged' field name is ` +
  `retained for orchestrator compat; under ADR-062 it means 'ticket keys verified', not 'merged'), stale=[], ` +
  `base_sha=$waveBase, and a one-paragraph report citing the commit count and the ordered keys observed.\n` +
  `  5. If the assertion fails (missing commit, wrong order, wrong prefix): return status='noop' or 'conflict' as ` +
  `fits, with a report naming the divergence. NEVER attempt to re-order or rewrite history.\n\n` +
  `Per-wave parallel-write conflicts cannot occur (one sequential writer); the within-wave shared-sink detection that ` +
  `the v1 engine ran here is moot and has been removed.`,
  { label: 'integrate', phase: 'integrate', agentType: 'implementer', schema: INTEGRATE_SCHEMA }
)
payload.integrate = integrate
if (!integrate || integrate.status !== 'integrated') {
  const st = integrate ? integrate.status : 'NULL'
  criterionFindings.push({
    gate: 'integrate', id: 'INTEGRATE',
    severity: 'critical', criterion_match: 'crit-1', recommended_disposition: 'ESCALATE',
    detail: `integration verification ${st}: ${integrate ? (integrate.report || '').slice(0, 400) : 'agent died'}`,
  })
  log(`integrate: ${st} — short-circuit surface (cannot gate an un-verified wave)`)
  return shortCircuit({ stoppedAt: 'integrate' })
}
log(`integrate: verified ${(integrate.merged || []).length} ticket(s) on wave branch -> ${(integrate.integrated_head || '').slice(0, 8)}`)

// --- BACK-END CROSS-WAVE DRIFT GATE (PEC-T6) — wire-to-consumer: the post-build control flow INVOKES
// the realized-state partition re-check. A drift is a genuine crit-1 (the build violated the disjoint-sink
// contract the plan validated) → it rides criterionFindings so the wave surfaces for the operator. SILENT
// on a clean run (no findings pushed). This is the realized-state half of the MUST-PASS partition net.
{
  const driftFindings = detectShippedSinkDrift(tickets, implementResults)
  payload.driftFindings = driftFindings
  for (const f of driftFindings) { allFindings.push(f); criterionFindings.push(f) }
  if (driftFindings.length) log(`drift-gate: FIRED — ${driftFindings.length} cross-wave partition drift(s) detected in realized state`)
  else log('drift-gate: clean — no cross-wave partition drift in the realized commit stream')
}

// ===========================================================================
// GATE + COVERAGE + ARCHITECT-FINAL. Runs over the integrated wave.
// ===========================================================================

// --- batch-gate (D5): code-reviewer + spec-conformance (+ contextual(s)) over the INTEGRATED diff ----
phase('gate')
// Diff base for the gate: the integrate verifier's reported base_sha (the wave-start point), else a
// fallback that walks back over the verified per-ticket commit count.
const diffBase = (integrate && integrate.base_sha && SHA_SHAPE.test(integrate.base_sha)) ? integrate.base_sha
  : (integrate && integrate.integrated_head ? `${integrate.integrated_head}~${(integrate.merged || []).length}` : 'HEAD~1')
const gateThunks = [
  () => agent(
    `Code-review the INTEGRATED wave diff in repo ${repoRoot} (inspect via \`git diff ${diffBase}..HEAD\` and reading files). ` +
    `This is the union of ${tickets.length} ticket(s).\n\n${specByPath()}\n\nReturn verdict + findings per the schema. ${CRIT}`,
    { label: 'gate:code-reviewer', phase: 'gate', agentType: 'code-reviewer', schema: FINDINGS_SCHEMA }
  ),
  () => agent(
    `Spec-conformance over the INTEGRATED wave in repo ${repoRoot}: does it satisfy the spec's acceptance criteria, ` +
    `per ticket? Inspect \`git diff ${diffBase}..HEAD\`.\n\n${specByPath()}\n\n` +
    `Return verdict (CONFORMS/DRIFT/GAP) + findings, with a per-ticket atom-coverage note in the summary. ${CRIT}`,
    { label: 'gate:spec-conformance', phase: 'gate', agentType: 'spec-conformance', schema: FINDINGS_SCHEMA }
  ),
]
for (const rev of gateReviewers) {
  gateThunks.push(() => agent(
    `Contextual review (${rev}) of the INTEGRATED wave diff in repo ${repoRoot} (\`git diff ${diffBase}..HEAD\`).\n\n` +
    `${specByPath()}\n\nReturn verdict + findings per the schema. ${CRIT}`,
    { label: `gate:${rev}`, phase: 'gate', agentType: rev, schema: FINDINGS_SCHEMA }
  ))
}
const gateResults = await parallel(gateThunks)
const review = gateResults[0]
const conformance = gateResults[1]
const contextualReviews = gateReviewers.map((rev, i) => ({ type: rev, result: gateResults[2 + i] || null }))
payload.review = review
payload.conformance = conformance
payload.contextualReviews = contextualReviews
harvest('code-reviewer', review)
harvest('spec-conformance', conformance)
for (const c of contextualReviews) harvest(c.type, c.result)

// --- AC coverage check (ADR-047 §3): every spec AC-NNN must be claimed by >=1 ticket ----
// Deterministic set-equality so a silently-dropped AC can't slip past on an LLM summary's
// judgement. Skips cleanly (no throw) when the spec mints no formal AC-NNN.
const specACs = [...new Set(specText.match(/\bAC-\d+\b/g) || [])]
if (specACs.length) {
  const claimedACs = new Set(tickets.flatMap(t => (t.acceptance || [])))
  const uncoveredACs = specACs.filter(ac => !claimedACs.has(ac))
  payload.coverageGap = uncoveredACs
  if (uncoveredACs.length) {
    criterionFindings.push({
      gate: 'coverage-check', id: 'AC-COVERAGE',
      severity: 'high', criterion_match: 'crit-1', recommended_disposition: 'ESCALATE',
      detail: `Spec acceptance criteria claimed by no ticket (silently dropped scope): ${uncoveredACs.join(', ')}. ` +
              `Every AC-NNN in the spec must appear in some ticket's acceptance[] (ADR-047 §3).`,
    })
    log(`coverage-check: GAP — ${uncoveredACs.length}/${specACs.length} spec AC(s) unclaimed: ${uncoveredACs.join(', ')}`)
  } else {
    log(`coverage-check: OK — all ${specACs.length} spec AC(s) claimed by >=1 ticket`)
  }
} else {
  log('coverage-check: skipped (spec mints no AC-NNN)')
}

// --- architect-review (FINAL pass — validates a CROSS-WAVE composition seam; ADR-062 §4 / ADR-063 §D4)
// Under one-implementer-per-wave there is no within-wave parallel-implement seam for architect-final
// to net (T-102 + T-103). The architect-final pass remains live ONLY when composing this wave with
// already-built prior waves — the `/orchestrate-epic` interleave case (ADR-059), signalled by the
// `crossWavePrior:true` arg. Default false → skip the phase entirely (no agent dispatch, no payload entry).
let archFinal = null
if (crossWavePrior) {
  phase('architect-final')
  archFinal = await agent(
    `architect-review (FINAL / POST-INTEGRATION pass): validate that this wave composes correctly with the ` +
    `prior-built waves on this epic branch (ADR-059 cross-wave seam). Repo: ${repoRoot}. Inspect \`git diff ${diffBase}..HEAD\` ` +
    `for the wave's contribution, and \`git log\` for the epic's prior-built waves.\n\n` +
    `ADR (pre-pass): read it at ${runDir}/adr.md (written by architect-review:pre)` +
    `${archPre.summary ? `. If that file is missing, the pre-pass summary is:\n${archPre.summary}` : ''}\n\n` +
    `${specByPath()}\n\n` +
    `Look specifically for CROSS-WAVE integration issues (seams against prior built waves, contract mismatches, ` +
    `duplicated/contradictory logic across waves). Return verdict (APPROVE/REQUEST_CHANGES) + findings. ${CRIT}`,
    { label: 'architect-review:final', phase: 'architect-final', agentType: 'architect-review', schema: ARCH_FINAL_SCHEMA }
  )
  payload.archFinal = archFinal
  harvest('architect-review:final', archFinal)
  if (archFinal && archFinal.verdict === 'REQUEST_CHANGES') {
    // ensure a surface even if individual findings were tagged 'none' — a REQUEST_CHANGES cross-wave
    // verdict is itself a material (crit-1) signal.
    if (!criterionFindings.some(f => f.gate === 'architect-review:final')) {
      criterionFindings.push({
        gate: 'architect-review:final', id: 'ARCH-FINAL',
        severity: 'high', criterion_match: 'crit-1', recommended_disposition: 'ESCALATE',
        detail: `architect-review (final) REQUEST_CHANGES on the cross-wave composition: ${(archFinal.summary || '').slice(0, 400)}`,
      })
    }
  }
}

// --- consolidated-surface computation (contract 3; ADR-036) ----------------
log(`gate complete: code-reviewer=${review && review.verdict} spec-conformance=${conformance && conformance.verdict}` +
    (gateReviewers.length ? ` [${gateReviewers.join(',')}]` : '') +
    (crossWavePrior ? ` architect-final=${archFinal && archFinal.verdict}` : ' architect-final=skipped(crossWavePrior=false)') +
    ` | ${allFindings.length} finding(s), ${criterionFindings.length} criterion-matched (surface-worthy)`)

return {
  track: 'orchestrated',
  ...payload,
  allFindings,
  criterionFindings,
  warnFindings,                                    // ADR-086 D4: informational WARNs (budget/atom-chain) — surface, no halt
  surfaceRequired: criterionFindings.length > 0,   // orchestrator performs the halt + wave-level commit
}
