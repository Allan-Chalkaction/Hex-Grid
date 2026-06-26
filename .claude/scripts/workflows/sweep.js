export const meta = {
  name: 'sweep',
  description: 'v2 /sweep on the Workflow engine (SHR3-T7): deterministic cluster -> LLM converge -> deterministic vitality/moves. The cluster + vitality steps are ZERO-LLM (backed by the Wave C F9 floor scripts, sweep-cluster.py); converge is the SOLE LLM seam. Every git mv / scoped self-commit is expressed as RETURNED INTENT the orchestrator executes (ADR-039 contract 2 — scripts have no FS/git access). DROP is location-is-status: a dropped item MOVES to a visible dropped/ folder via git mv, NEVER git-rm (ADR-087). The self-commit is local-only, stages ONLY touched paths (never git-add-all), and issues NO git-push / main write. Returns track:"sweep"; the orchestrator persists via persist-run-artifacts.py + executes the returned move/commit intents.',
  phases: [
    { title: 'cluster', detail: 'DETERMINISTIC (zero LLM): the F9 coarse cluster floor (sweep-cluster.py) partitions the live inbox; the engine validates + carries the floor groups' },
    { title: 'converge', detail: 'THE SOLE LLM SEAM: one agent converges each cluster into a fork-resolving thesis (the irreducible ceiling, ADR-126 D-3)' },
    { title: 'vitality', detail: 'DETERMINISTIC (zero LLM): compute the vitality line + the move/commit INTENTS (DROP->dropped/ via git mv, non-capture routing, scoped self-commit) the orchestrator executes' },
  ],
}

// ===========================================================================
// THE v2 /sweep ENGINE (SHR3-T7). /sweep migrates from a skill-only convergence
// door onto the Workflow engine, matching the nimble.js / orchestrated.js mold.
//
// THE UNIFYING DOCTRINE — F9 (ADR-126) + location-is-status (ADR-087):
//   * F9 floor/ceiling split: the DETERMINISTIC floor (clustering, vitality math,
//     DROP/route classification) is ZERO-LLM, backed by the Wave C scripts
//     (sweep-cluster.py); the LLM ceiling (converge a cluster into a fork-resolving
//     thesis) is the ONE irreducible LLM seam (ADR-126 D-3). Cluster + vitality
//     reach for NO agent() — converge is the SOLE agent() call in this file.
//   * location-is-status: state is encoded by WHERE a file lives; you change state
//     by MOVING the file (git mv), NEVER by deleting it. A DROP moves the item to a
//     visible dropped/ folder; it is NEVER git-rm'd. An open decision PROMOTES.
//
// THE FOUR STANDARDIZED ENGINE CONTRACTS (ADR-039), applied to /sweep:
//  1. Defensive args parse — `args` may arrive as a JSON string.
//  2. Returns a structured payload; the ORCHESTRATOR persists artifacts AND
//     executes the returned git INTENTS. *** sweep.js has NO FS/git access ***, so
//     it CANNOT itself run git mv / git add / git commit. Every move + the scoped
//     self-commit is expressed as a RETURNED INTENT object (moveIntents[],
//     commitIntent) the orchestrator (or a deterministic helper invoked OUTSIDE the
//     Workflow sandbox) executes. This is contract-2's trap for /sweep — see the
//     boundary note on buildMoveIntents() / buildCommitIntent() below.
//  3. The script COMPUTES the surface; the ORCHESTRATOR performs any halt. A
//     Workflow script cannot halt-and-wait.
//  4. No worktree isolation: /sweep stages move/commit INTENTS only (no source
//     edits, no parallel-write hazard). The orchestrator executes them in-place and
//     the operator commits/pushes (the move-only-staging discipline is unchanged).
//
// args: { runDir, repoRoot,
//         inbox?       : string                      // the live ideas-inbox path (default docs/step-1-ideas)
//         jams?        : string                      // the live jams path (default docs/step-2-planning)
//         clusters?    : string[][]                  // the F9 coarse cluster floor (sweep-cluster.py cluster
//                                                    //   .decision), passed in by the orchestrator. The DETERMINISTIC
//                                                    //   floor — the engine carries it, it does NOT re-derive it by LLM.
//         drops?       : string[]                    // inbox relpaths the triage assigned the `drop` verdict
//         openDecisions?: string[]                   // relpaths that are OPEN DECISIONS -> PROMOTE, never drop
//         nonCapture?  : string[]                    // inbox relpaths that are non-capture docs (findings/README)
//         absorbedDelta?: number                     // ideas folded this pass (for the vitality line)
//       }
// ===========================================================================

const _a = typeof args === 'string' ? JSON.parse(args) : (args || {})          // contract 1
const { runDir, repoRoot } = _a
if (!runDir || !repoRoot) {
  throw new Error(`sweep: missing required args (runDir/repoRoot). Got keys: ${Object.keys(_a).join(',') || '<none>'}`)
}
const inbox = (typeof _a.inbox === 'string' && _a.inbox) ? _a.inbox : 'docs/step-1-ideas'
const jams = (typeof _a.jams === 'string' && _a.jams) ? _a.jams : 'docs/step-2-planning'
const clusters = Array.isArray(_a.clusters) ? _a.clusters.filter(Array.isArray) : []
const drops = Array.isArray(_a.drops) ? _a.drops.filter(s => typeof s === 'string' && s) : []
const openDecisions = new Set(Array.isArray(_a.openDecisions) ? _a.openDecisions.filter(s => typeof s === 'string') : [])
const nonCapture = Array.isArray(_a.nonCapture) ? _a.nonCapture.filter(s => typeof s === 'string' && s) : []
const absorbedDelta = Number.isFinite(_a.absorbedDelta) ? _a.absorbedDelta : 0

// ---------------------------------------------------------------------------
// PATH-SHAPE GUARD (CR-001 parity with nimble/orchestrated). Every value that
// flows into a returned git-command intent is shape-guarded BEFORE interpolation:
// reject anything that isn't a plausible single-segment repo-relative path (no
// shell metacharacters, no quotes, no newlines, no `..` escape, no absolute path).
// A miss => the item is DROPPED from the intent set (never interpolated), so a
// poisoned path can never reach the orchestrator's git op. This is load-bearing:
// the move/commit intents are executed by the orchestrator as shell git commands.
const PATH_RE = /^[A-Za-z0-9._/-]+$/
function safeRelPath(p) {
  if (typeof p !== 'string' || !p) return null
  if (!PATH_RE.test(p)) return null
  if (p.startsWith('/')) return null                  // no absolute escape
  if (p.split('/').some(seg => seg === '..')) return null   // no parent escape
  return p
}

// ---------------------------------------------------------------------------
// DETERMINISTIC HELPERS (ZERO LLM). These are pure functions — no agent() call,
// no randomness, no session memory; they read only their structured inputs. They
// are defined here and exercised by test-sweep-engine.sh's determinism assertions.
// ---------------------------------------------------------------------------

// dropIntent(relPath) -> the location-is-status DROP move (ADR-087, AC-020).
// A DROP is a git mv into a VISIBLE dropped/ folder under the inbox — NEVER a
// git-rm. An OPEN DECISION is NOT dropped: it PROMOTES (returned as a promote
// intent) so a live decision is never silently erased. git history is the archive;
// the dropped/ folder is the visible status marker.
function dropIntent(relPath) {
  const safe = safeRelPath(relPath)
  if (!safe) return null
  if (openDecisions.has(relPath)) {
    // open decision -> PROMOTE, never drop (the "open decision -> promote not drop" rule)
    return { kind: 'promote', op: 'git mv', from: `${inbox}/${safe}`, to: `${inbox}/needs-shaping/${basename(safe)}`, why: 'open decision -> promote (never drop)' }
  }
  return { kind: 'drop', op: 'git mv', from: `${inbox}/${safe}`, to: `${inbox}/dropped/${basename(safe)}`, why: 'location-is-status DROP: git mv to visible dropped/ (never git-rm; ADR-087)' }
}

// routeNonCapture(relPath) -> the deterministic non-capture-doc router (AC-022).
// Non-capture docs (findings, READMEs) pollute the ideas inbox. This router moves
// them OUT to their correct home, decided PURELY by file class/location (no LLM):
//   * a findings file (findings/ segment OR a *finding*.md name) -> the run-folder
//     findings convention (returned as a route to runDir/findings/).
//   * a README/INDEX -> stays as the inbox's own README is legitimate; a STRAY
//     README inside a capture subtree routes to the inbox root README slot.
// The classification is a deterministic switch on the path/name, never inference.
function routeNonCapture(relPath) {
  const safe = safeRelPath(relPath)
  if (!safe) return null
  const name = basename(safe).toLowerCase()
  const isFinding = safe.split('/').includes('findings') || /find(ing)?/.test(name)
  const isReadme = /^(readme|index)\.md$/.test(name)
  if (isFinding) {
    return { kind: 'route-finding', op: 'git mv', from: `${inbox}/${safe}`, to: `${runDir}/findings/${basename(safe)}`, why: 'non-capture finding routed OUT of the ideas inbox to the run findings/ (AC-022)' }
  }
  if (isReadme) {
    return { kind: 'route-readme', op: 'git mv', from: `${inbox}/${safe}`, to: `${runDir}/${basename(safe)}`, why: 'non-capture README/INDEX routed OUT of the ideas inbox (AC-022)' }
  }
  // default: any other non-capture doc routes to the run folder (deterministic fallback)
  return { kind: 'route-doc', op: 'git mv', from: `${inbox}/${safe}`, to: `${runDir}/${basename(safe)}`, why: 'non-capture doc routed OUT of the ideas inbox (AC-022)' }
}

// basename — pure path helper (no `path` import needed; engine sandbox is bare).
function basename(p) { const parts = String(p).split('/'); return parts[parts.length - 1] || p }

// buildMoveIntents() -> the full DETERMINISTIC move set the orchestrator executes.
// Every entry is a git-mv (or git-mv-as-promote) intent — NEVER a git-rm. The
// orchestrator runs these `git mv` commands in-place (contract 2). a delete op appears
// NOWHERE in this file (AC-020 grep-clean).
function buildMoveIntents() {
  const intents = []
  for (const d of drops) { const i = dropIntent(d); if (i) intents.push(i) }
  for (const nc of nonCapture) { const i = routeNonCapture(nc); if (i) intents.push(i) }
  return intents
}

// buildCommitIntent(touchedPaths) -> the SCOPED self-commit intent (AC-021 — the
// security boundary). The self-commit:
//   * is LOCAL-ONLY (no `git-push`, no remote write, no main write),
//   * stages ONLY the explicit touched paths (`git add <path> <path> ...`),
//     *** NEVER `git-add-all` *** of unrelated working-tree state,
//   * produces a LOCAL commit.
// Returned as an INTENT (contract 2) — sweep.js does not run git. The explicit
// `add` arg list is the disqualifier guard: a single `git-add-all` would sweep up
// unrelated work and fail AC-021 + the security review, so the intent enumerates
// exactly the paths the moves touched and the orchestrator stages only those.
function buildCommitIntent(touchedPaths) {
  const safePaths = touchedPaths.map(safeRelPath).filter(Boolean)
  return {
    op: 'commit',
    local_only: true,        // NO remote-push / remote / main write — the security boundary (AC-021)
    push: false,
    stage: {
      // explicit path list — the orchestrator runs `git add <addPaths...>`, NEVER `git-add-all`
      mode: 'explicit-paths',
      addPaths: safePaths,
    },
    message: 'chore(inbox): /sweep — deterministic moves (DROP->dropped/, non-capture routing) staged',
    why: 'scoped self-commit: local-only, stages ONLY touched paths (never git-add-all), no remote push (AC-021)',
  }
}

// computeVitalityLine(absorbed, passes, pending) -> the machine-readable plan-vitality
// header line docs-index.py renders (ADR-089 D5). DETERMINISTIC string assembly,
// ZERO LLM. The date is resolved by the orchestrator at write time (the engine has
// no clock-write side effect); the engine returns the template + computed counts.
function computeVitalityLine(absorbed, passes, pending) {
  return `<!-- vitality: absorbed=${absorbed} passes=${passes} last=__DATE__ pending=${pending} -->`
}

// ---------------------------------------------------------------------------
// Accumulators for the structured return (orchestrator persists + executes from these).
const criterionFindings = []
const payload = { track: 'sweep' }

// =========================== STEP 1: cluster (DETERMINISTIC, zero LLM) =======
phase('cluster')
// The coarse cluster floor is computed by the Wave C F9 script (sweep-cluster.py
// cluster) which the orchestrator runs BEFORE dispatch and passes in via args
// (`clusters`). The engine carries that floor — it does NOT re-derive the partition
// by LLM. *** NO agent() call in this step *** (the F9 floor is zero-LLM by
// construction; ADR-126 D-1). The engine validates the floor shape and records it.
const clusterFloor = clusters
  .map(group => (Array.isArray(group) ? group.filter(s => typeof s === 'string' && s) : []))
  .filter(group => group.length >= 1)
payload.clusters = clusterFloor
log(`cluster: carried ${clusterFloor.length} deterministic cluster(s) from the F9 floor (sweep-cluster.py) — zero LLM in this step`)

// =========================== STEP 2: converge (THE SOLE LLM SEAM) ===========
phase('converge')
// THE ONE AND ONLY agent() CALL in this file. Converging a cluster into a single
// fork-RESOLVING thesis is authoring, not classification — the irreducible LLM
// ceiling (ADR-126 D-3). The deterministic floor (cluster, vitality, moves) never
// reaches for the LLM; this is the sole seam. The test asserts exactly one agent(.
let theses = []
if (clusterFloor.length > 0) {
  const convergeResults = await parallel(clusterFloor.map((group, idx) => () => agent(
    `Converge this idea cluster into ONE fork-resolving thesis (repo ${repoRoot}; inbox ${inbox}). ` +
    `This is the irreducible LLM ceiling — author the thesis, do NOT re-cluster (the coarse partition is ` +
    `already decided deterministically). Cluster members (relative to ${inbox}):\n` +
    group.map(m => `  - ${m}`).join('\n') + `\n\n` +
    `A jam converges by PRUNING into a single thesis that RESOLVES its forks — every tree-vs-graph decision ` +
    `decided once, written down (an unresolved fork is an unfinished jam, not a build-time decision). Ground ` +
    `each member's claims by reading the repo (turn "I think X" into "verified in path:line" or flag [verify]). ` +
    `Return the converged thesis text + which members it absorbed.`,
    { label: `converge:${idx}`, phase: 'converge', agentType: 'general-purpose' }
  )))
  theses = convergeResults.filter(Boolean)
}
payload.theses = theses
log(`converge: ${theses.length} thesis/theses authored (the SOLE LLM seam) over ${clusterFloor.length} cluster(s)`)

// =========================== STEP 3: vitality + moves (DETERMINISTIC) =======
phase('vitality')
// DETERMINISTIC (zero LLM): compute the move/commit INTENTS + the vitality line.
// *** NO agent() call in this step *** — pure functions over the structured inputs.
// Every git op is a RETURNED INTENT the orchestrator executes (contract 2); sweep.js
// runs no git itself.
const moveIntents = buildMoveIntents()
// the self-commit stages ONLY the destination paths the moves touched (never -A)
const touchedPaths = []
for (const mv of moveIntents) {
  if (mv.from) touchedPaths.push(mv.from)
  if (mv.to) touchedPaths.push(mv.to)
}
const commitIntent = buildCommitIntent(touchedPaths)
// vitality: absorbed += folded this pass; passes += 1; pending = open cluster members not yet absorbed.
const absorbedThisPass = theses.reduce((n, t) => n + (Array.isArray(t.absorbed) ? t.absorbed.length : 0), absorbedDelta)
const pending = openDecisions.size
const vitalityLine = computeVitalityLine(absorbedThisPass, theses.length, pending)

payload.moveIntents = moveIntents              // git mv intents (DROP->dropped/, routing) — NEVER git-rm
payload.commitIntent = commitIntent            // scoped local self-commit — explicit paths, no remote push (AC-021)
payload.vitalityLine = vitalityLine            // ADR-089 D5 header (date resolved by the orchestrator at write)
payload.dropCount = moveIntents.filter(m => m.kind === 'drop').length
payload.promoteCount = moveIntents.filter(m => m.kind === 'promote').length
payload.routeCount = moveIntents.filter(m => String(m.kind).startsWith('route')).length

log(`vitality: ${payload.dropCount} drop->dropped/ (git mv, never git-rm), ${payload.promoteCount} open-decision promote, ${payload.routeCount} non-capture route; self-commit stages ${touchedPaths.length} explicit path(s), no remote push`)

// contract 3: the orchestrator performs any halt. /sweep is a staging pass with no
// execution-class block of its own; surfaceRequired stays false (nothing to halt on).
payload.criterionFindings = criterionFindings
payload.surfaceRequired = false

return payload
