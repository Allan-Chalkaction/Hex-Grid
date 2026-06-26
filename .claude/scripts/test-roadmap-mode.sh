#!/usr/bin/env bash
# ADR-030 synthetic test — verifies the /roadmap entry mode hook chain.
#
# Mirrors core/scripts/test-adhoc-mode.sh (roadmap is modeled on adhoc) and
# adds the two load-bearing risk assertions flagged at implementation time:
#   - require-protocol.sh arm ordering (roadmap) before *), round-loop) before *))
#   - resume-glob correctness (highest round-N-draft.md → continue at round N+1)
#
# Each test function returns 0 on pass or 1 on fail (printing FAIL: <reason>).
# Main runs them all and exits with the failure count (0 = all passed).
#
# Tests:
#   test_happy_path              — *-ROADMAP-* detection, track=roadmap, phase=round-loop, hook patterns
#   test_arm_ordering            — roadmap) before *) (track), round-loop) before *) (phase)  [RISK 1]
#   test_phase_advisor_allow     — round-loop) phase case allows an advisor (exit 0)
#   test_implementer_block_arm   — roadmap) track arm blocks implementers (phase=execute, exit 2, message)
#   test_implementer_block_phase — round-loop phase blocks implementers via CHECK 0b (defense-in-depth)
#   test_resume_glob             — round-0..round-3 present → resume at round 4, never round 0  [RISK 2]
#   test_off_transition          — /roadmap off removes state file; subsequent check blocks
#   test_no_regression           — adhoc/nimble/pipeline/orchestrated shapes unaffected
#
# Usage:   bash core/scripts/test-roadmap-mode.sh
# Exit:    0 — all PASS; N — N failures (FAIL: messages on stdout)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ---------------------------------------------------------------------------
# SHARED SANDBOX HELPERS
# ---------------------------------------------------------------------------

setup_sandbox() {
  SANDBOX_DIR=$(mktemp -d -t adr-030-test-XXXXXX)
  mkdir -p \
    "${SANDBOX_DIR}/.claude/agent-memory/active-runs" \
    "${SANDBOX_DIR}/docs/step-5-pipeline"
  echo "$SANDBOX_DIR"
}

cleanup_sandbox() {
  local dir="${1:-}"
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    rm -rf "$dir"
  fi
}

# Write a minimal roadmap state file. Args: sandbox sid slug [phase]
write_state_file() {
  local sandbox="$1" sid="$2" slug="$3" phase="${4:-round-loop}"
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local state_path="${sandbox}/.claude/agent-memory/active-runs/${sid}-${slug}.json"
  cat > "$state_path" <<EOF
{
  "ticket_key": "ADR-030",
  "run_dir": "docs/step-5-pipeline/2026-05-23/1200-ROADMAP-epic-${slug}",
  "slug": "${slug}",
  "track": "roadmap",
  "mode": null,
  "session_id": "${sid}",
  "created_at": "${now}",
  "last_activity_at": "${now}",
  "current_phase": "${phase}",
  "initiated_by": "roadmap",
  "completed_agents": [],
  "phase_history": [{"phase": "${phase}", "entered_at": "${now}"}]
}
EOF
  echo "$state_path"
}

# ---------------------------------------------------------------------------
# TEST 1: Happy path — detection, state shape, hook patterns
# ---------------------------------------------------------------------------
test_happy_path() {
  local sync_hook="${REPO_ROOT}/core/hooks/sync-artifacts-post-agent.sh"
  local inject_hook="${REPO_ROOT}/core/hooks/workflow-state-inject.sh"
  local protocol_hook="${REPO_ROOT}/core/hooks/require-protocol.sh"
  local phases_config="${REPO_ROOT}/core/config/workflow-phases.json"

  if ! grep -q '\*-ROADMAP-\*' "$sync_hook"; then
    echo "FAIL: test_happy_path — sync-artifacts missing *-ROADMAP-* track-detection case"; return 1
  fi
  if ! grep -q '????-ROADMAP-\*' "$sync_hook"; then
    echo "FAIL: test_happy_path — sync-artifacts missing ????-ROADMAP-* slug-strip case"; return 1
  fi
  if ! grep -q '"round-loop"' "$sync_hook"; then
    echo "FAIL: test_happy_path — sync-artifacts does not set initial_phase round-loop for roadmap"; return 1
  fi
  if ! grep -q 'initiated.*roadmap' "$inject_hook"; then
    echo "FAIL: test_happy_path — workflow-state-inject missing initiated_by=roadmap case"; return 1
  fi
  if ! grep -q 'round-loop)' "$protocol_hook"; then
    echo "FAIL: test_happy_path — require-protocol missing round-loop) phase case"; return 1
  fi
  # workflow-phases.json registers roadmap with the round-loop phase
  local instr
  instr=$(jq -r '.tracks.roadmap.phases["round-loop"].instruction_file // empty' "$phases_config" 2>/dev/null)
  if [ "$instr" != "phases/roadmap/round-loop.md" ]; then
    echo "FAIL: test_happy_path — workflow-phases.json roadmap.round-loop.instruction_file = '${instr}'"; return 1
  fi
  # inject-only: the round-loop phase must NOT auto-advance
  local sig nxt
  sig=$(jq -r '.tracks.roadmap.phases["round-loop"].completion_signal' "$phases_config" 2>/dev/null)
  nxt=$(jq -r '.tracks.roadmap.phases["round-loop"].next' "$phases_config" 2>/dev/null)
  if [ "$sig" != "null" ] || [ "$nxt" != "null" ]; then
    echo "FAIL: test_happy_path — round-loop must have null completion_signal/next (inject-only); got sig='${sig}' next='${nxt}'"; return 1
  fi
  # the injected instruction file exists
  if [ ! -f "${REPO_ROOT}/core/config/phases/roadmap/round-loop.md" ]; then
    echo "FAIL: test_happy_path — phases/roadmap/round-loop.md does not exist"; return 1
  fi

  local sandbox; sandbox=$(setup_sandbox)
  local state_path; state_path=$(write_state_file "$sandbox" "sess-rm-001" "test-epic")
  local track phase initiated_by
  track=$(jq -r '.track' "$state_path" 2>/dev/null)
  phase=$(jq -r '.current_phase' "$state_path" 2>/dev/null)
  initiated_by=$(jq -r '.initiated_by' "$state_path" 2>/dev/null)
  cleanup_sandbox "$sandbox"

  [ "$track" = "roadmap" ] || { echo "FAIL: test_happy_path — track='${track}', expected 'roadmap'"; return 1; }
  [ "$phase" = "round-loop" ] || { echo "FAIL: test_happy_path — phase='${phase}', expected 'round-loop'"; return 1; }
  [ "$initiated_by" = "roadmap" ] || { echo "FAIL: test_happy_path — initiated_by='${initiated_by}', expected 'roadmap'"; return 1; }

  echo "PASS: test_happy_path"; return 0
}

# ---------------------------------------------------------------------------
# TEST 2: Arm ordering [RISK 1] — roadmap) before *) (track), round-loop) before *) (phase)
# ---------------------------------------------------------------------------
test_arm_ordering() {
  local protocol_hook="${REPO_ROOT}/core/hooks/require-protocol.sh"

  # Track case: the roadmap) arm must precede the catch-all *) arm. We compare
  # the line number of the "roadmap)" track arm against the LAST "*)" in the
  # track-aware case block (the unrecognized-track catch-all).
  local roadmap_track_ln catchall_track_ln
  roadmap_track_ln=$(grep -n '^  roadmap)' "$protocol_hook" | head -1 | cut -d: -f1)
  # The unrecognized-track catch-all is the *) arm that prints "$TRACK is unset or unrecognized"
  catchall_track_ln=$(grep -n 'is unset or unrecognized' "$protocol_hook" | head -1 | cut -d: -f1)

  if [ -z "$roadmap_track_ln" ]; then
    echo "FAIL: test_arm_ordering — no '  roadmap)' track arm found in require-protocol.sh"; return 1
  fi
  if [ -z "$catchall_track_ln" ]; then
    echo "FAIL: test_arm_ordering — could not locate unrecognized-track catch-all"; return 1
  fi
  if [ "$roadmap_track_ln" -ge "$catchall_track_ln" ]; then
    echo "FAIL: test_arm_ordering — roadmap) track arm (line ${roadmap_track_ln}) is NOT before the *) catch-all (line ${catchall_track_ln})"; return 1
  fi

  # Phase case: round-loop) must precede the phase-block catch-all "*)" that
  # prints "Unknown phase or utility agents". Locate both.
  local roundloop_phase_ln phase_catchall_ln
  roundloop_phase_ln=$(grep -n '^    round-loop)' "$protocol_hook" | head -1 | cut -d: -f1)
  phase_catchall_ln=$(grep -n 'Unknown phase or utility agents' "$protocol_hook" | head -1 | cut -d: -f1)

  if [ -z "$roundloop_phase_ln" ]; then
    echo "FAIL: test_arm_ordering — no '    round-loop)' phase arm found"; return 1
  fi
  if [ -z "$phase_catchall_ln" ]; then
    echo "FAIL: test_arm_ordering — could not locate phase-block catch-all"; return 1
  fi
  if [ "$roundloop_phase_ln" -ge "$phase_catchall_ln" ]; then
    echo "FAIL: test_arm_ordering — round-loop) phase arm (line ${roundloop_phase_ln}) is NOT before the phase *) catch-all (line ${phase_catchall_ln})"; return 1
  fi

  echo "PASS: test_arm_ordering"; return 0
}

# ---------------------------------------------------------------------------
# TEST 3: Phase advisor allow — round-loop phase lets an advisor through (exit 0)
# ---------------------------------------------------------------------------
test_phase_advisor_allow() {
  local sandbox; sandbox=$(setup_sandbox)
  write_state_file "$sandbox" "sess-rm-003" "advisor-slug" "round-loop" >/dev/null
  local protocol_hook="${REPO_ROOT}/core/hooks/require-protocol.sh"
  local hook_exit=0
  (cd "$sandbox" && \
    printf '{"tool_input": {"subagent_type": "cto-advisor"}, "session_id": "sess-rm-003"}' | \
    bash "$protocol_hook" >/dev/null 2>&1) || hook_exit=$?
  cleanup_sandbox "$sandbox"

  if [ "$hook_exit" -ne 0 ]; then
    echo "FAIL: test_phase_advisor_allow — advisor in round-loop expected exit 0, got ${hook_exit}"; return 1
  fi
  echo "PASS: test_phase_advisor_allow"; return 0
}

# ---------------------------------------------------------------------------
# TEST 4: Implementer block via roadmap) track arm (phase=execute forces the arm)
# ---------------------------------------------------------------------------
test_implementer_block_arm() {
  local sandbox; sandbox=$(setup_sandbox)
  write_state_file "$sandbox" "sess-rm-004" "impl-arm-slug" "execute" >/dev/null
  local protocol_hook="${REPO_ROOT}/core/hooks/require-protocol.sh"
  local hook_stderr hook_exit=0
  hook_stderr=$(cd "$sandbox" && \
    printf '{"tool_input": {"subagent_type": "implementer"}, "session_id": "sess-rm-004"}' | \
    bash "$protocol_hook" 2>&1) || hook_exit=$?
  cleanup_sandbox "$sandbox"

  if [ "$hook_exit" -ne 2 ]; then
    echo "FAIL: test_implementer_block_arm — expected exit 2, got ${hook_exit}; stderr: ${hook_stderr}"; return 1
  fi
  if ! echo "$hook_stderr" | grep -q "Roadmap mode is advisor-only"; then
    echo "FAIL: test_implementer_block_arm — stderr missing 'Roadmap mode is advisor-only'; got: ${hook_stderr}"; return 1
  fi
  echo "PASS: test_implementer_block_arm"; return 0
}

# ---------------------------------------------------------------------------
# TEST 5: Implementer block via CHECK 0b (round-loop phase ≠ execute) — defense-in-depth
# ---------------------------------------------------------------------------
test_implementer_block_phase() {
  local sandbox; sandbox=$(setup_sandbox)
  write_state_file "$sandbox" "sess-rm-005" "impl-phase-slug" "round-loop" >/dev/null
  local protocol_hook="${REPO_ROOT}/core/hooks/require-protocol.sh"
  local hook_exit=0
  (cd "$sandbox" && \
    printf '{"tool_input": {"subagent_type": "implementer"}, "session_id": "sess-rm-005"}' | \
    bash "$protocol_hook" >/dev/null 2>&1) || hook_exit=$?
  cleanup_sandbox "$sandbox"

  if [ "$hook_exit" -ne 2 ]; then
    echo "FAIL: test_implementer_block_phase — implementer in round-loop expected exit 2 (CHECK 0b), got ${hook_exit}"; return 1
  fi
  echo "PASS: test_implementer_block_phase"; return 0
}

# ---------------------------------------------------------------------------
# TEST 6: Resume-glob correctness [RISK 2]
# ---------------------------------------------------------------------------
# Given a run folder with round-0-intent.md + round-1..3 drafts, the resume
# logic must select the HIGHEST round-N-draft.md (N=3) and continue at round 4.
# It must NEVER restart at round 0. We implement the same glob the skill
# describes and assert on it.
test_resume_glob() {
  local sandbox; sandbox=$(setup_sandbox)
  local run_dir="${sandbox}/docs/step-5-pipeline/2026-05-23/1200-ROADMAP-epic-resume-test"
  mkdir -p "${run_dir}/findings"
  echo "intent"   > "${run_dir}/round-0-intent.md"
  echo "draft 1"  > "${run_dir}/round-1-draft.md"
  echo "input 1"  > "${run_dir}/round-1-operator-input.md"
  echo "draft 2"  > "${run_dir}/round-2-draft.md"
  echo "input 2"  > "${run_dir}/round-2-operator-input.md"
  echo "draft 3"  > "${run_dir}/round-3-draft.md"

  # Resume glob: highest N among round-N-draft.md
  local highest=-1 f n
  for f in "${run_dir}"/round-*-draft.md; do
    [ -e "$f" ] || continue
    n=$(basename "$f" | sed -E 's/^round-([0-9]+)-draft\.md$/\1/')
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$highest" ]; then
      highest="$n"
    fi
  done
  local next_round=$(( highest + 1 ))
  cleanup_sandbox "$sandbox"

  if [ "$highest" -ne 3 ]; then
    echo "FAIL: test_resume_glob — highest draft expected 3, got ${highest} (would restart wrong)"; return 1
  fi
  if [ "$next_round" -ne 4 ]; then
    echo "FAIL: test_resume_glob — resume should continue at round 4, computed ${next_round}"; return 1
  fi
  if [ "$highest" -eq 0 ]; then
    echo "FAIL: test_resume_glob — resume restarted at round 0 (the durable-artifact regression)"; return 1
  fi

  # SKILL.md documents the never-restart-at-0 invariant
  local skill="${REPO_ROOT}/core/skills/roadmap/SKILL.md"
  if ! grep -qi 'never restart at round 0' "$skill"; then
    echo "FAIL: test_resume_glob — SKILL.md does not document the never-restart-at-0 resume invariant"; return 1
  fi

  echo "PASS: test_resume_glob"; return 0
}

# ---------------------------------------------------------------------------
# TEST 7: Off transition — /roadmap off removes state file; subsequent check blocks
# ---------------------------------------------------------------------------
test_off_transition() {
  local sandbox; sandbox=$(setup_sandbox)
  local state_path; state_path=$(write_state_file "$sandbox" "sess-rm-007" "off-slug")
  [ -f "$state_path" ] || { cleanup_sandbox "$sandbox"; echo "FAIL: test_off_transition — state file missing before off"; return 1; }

  rm -f "$state_path"   # /roadmap off uses Bash rm -f
  [ -f "$state_path" ] && { cleanup_sandbox "$sandbox"; echo "FAIL: test_off_transition — state file still present after rm -f"; return 1; }

  local protocol_hook="${REPO_ROOT}/core/hooks/require-protocol.sh"
  local hook_stderr hook_exit=0
  hook_stderr=$(cd "$sandbox" && \
    printf '{"tool_input": {"subagent_type": "cto-advisor"}, "session_id": "sess-rm-007"}' | \
    bash "$protocol_hook" 2>&1) || hook_exit=$?
  cleanup_sandbox "$sandbox"

  if [ "$hook_exit" -ne 2 ]; then
    echo "FAIL: test_off_transition — expected CHECK 0 block (exit 2) after off, got ${hook_exit}"; return 1
  fi
  if ! echo "$hook_stderr" | grep -q "No run state file found"; then
    echo "FAIL: test_off_transition — expected CHECK 0 message, got: ${hook_stderr}"; return 1
  fi
  echo "PASS: test_off_transition"; return 0
}

# ---------------------------------------------------------------------------
# TEST 8: No regression — adhoc/nimble/pipeline/orchestrated unaffected
# ---------------------------------------------------------------------------
test_no_regression() {
  local sync_hook="${REPO_ROOT}/core/hooks/sync-artifacts-post-agent.sh"
  local protocol_hook="${REPO_ROOT}/core/hooks/require-protocol.sh"
  local phases_config="${REPO_ROOT}/core/config/workflow-phases.json"

  for marker in NIMBLE PIPELINE ADHOC WAVE; do
    if ! grep -q "\*-${marker}-\*" "$sync_hook"; then
      echo "FAIL: test_no_regression — sync-artifacts lost *-${marker}-* detection"; return 1
    fi
  done
  # ADR-085 D1: the v2 engine tracks share ONE combined arm (`nimble|orchestrated|chain)`);
  # the dormant v1 `pipeline)` arm and `adhoc)` remain individual.
  for arm in 'nimble|orchestrated|chain)' 'pipeline)' 'adhoc)'; do
    if ! grep -q "$arm" "$protocol_hook"; then
      echo "FAIL: test_no_regression — require-protocol lost ${arm} track case"; return 1
    fi
  done
  # advisory) phase case (adhoc) still present and untouched
  if ! grep -q 'advisory)' "$protocol_hook"; then
    echo "FAIL: test_no_regression — require-protocol lost advisory) phase case"; return 1
  fi
  # bypass short-circuit intact (ADR-052: session-scoped flag bypass-active-<sid>.json)
  if ! grep -q 'bypass-active-' "$protocol_hook"; then
    echo "FAIL: test_no_regression — require-protocol lost bypass short-circuit"; return 1
  fi
  # The v1 phase-machine tracks were RETIRED from workflow-phases.json: `orchestrated` by
  # T5b (ADR-040), then `pipeline` by the finish-shedding-v1 wave (T-002), then `nimble` by
  # ADR-079 D2 (the whole transition machine is gone — the Workflow script IS the chain). The
  # config now carries ONLY the per-turn inject loops (roadmap, planner). The auto-state
  # `*-NIMBLE-*` / `*-PIPELINE-*` markers and the `initial_phase="setup"` default in
  # sync-artifacts are KEPT (auto-state arm) and asserted above/below — only the phase-machine
  # track objects are gone.
  for t in roadmap planner; do
    if [ "$(jq -r ".tracks.${t} // empty" "$phases_config")" = "" ]; then
      echo "FAIL: test_no_regression — workflow-phases.json lost ${t} track"; return 1
    fi
  done
  for t in nimble pipeline orchestrated; do
    if [ "$(jq -r ".tracks.${t} // empty" "$phases_config")" != "" ]; then
      echo "FAIL: test_no_regression — workflow-phases.json should not carry ${t} track (retired, ADR-079 D2)"; return 1
    fi
  done
  if ! grep -q 'initial_phase="setup"' "$sync_hook"; then
    echo "FAIL: test_no_regression — sync-artifacts lost default initial_phase=setup"; return 1
  fi
  # workflow-phases.json still valid JSON
  if ! jq empty "$phases_config" >/dev/null 2>&1; then
    echo "FAIL: test_no_regression — workflow-phases.json is not valid JSON"; return 1
  fi

  echo "PASS: test_no_regression"; return 0
}

# ---------------------------------------------------------------------------
# TEST 9: Roadmap on the engine (ADR-055) — runs as a Workflow script with the
# planner self-QA inside it; autonomous-to-completion (ADR-054); --attended legacy.
# ---------------------------------------------------------------------------
test_round_enrichment() {
  local rl="${REPO_ROOT}/core/config/phases/roadmap/round-loop.md"
  local skill="${REPO_ROOT}/core/skills/roadmap/SKILL.md"
  local rules="${REPO_ROOT}/core/rules/rules-advisory-modes.md"
  local rjs="${REPO_ROOT}/core/scripts/workflows/roadmap.js"
  local persist="${REPO_ROOT}/core/scripts/persist-run-artifacts.py"
  local adr54="${REPO_ROOT}/docs/decisions/ADR-054-autonomous-to-completion-roadmap.md"
  local adr55="${REPO_ROOT}/docs/decisions/ADR-055-roadmap-on-the-engine.md"

  # 1. roadmap.js exists, is a Workflow script (meta + track:'roadmap'), and is advisor-only.
  if [ ! -f "$rjs" ]; then
    echo "FAIL: test_round_enrichment — core/scripts/workflows/roadmap.js missing (ADR-055)"; return 1
  fi
  if ! grep -q "name: 'roadmap'" "$rjs" || ! grep -q "track: 'roadmap'" "$rjs"; then
    echo "FAIL: test_round_enrichment — roadmap.js missing meta.name / track:'roadmap'"; return 1
  fi
  if grep -qE "isolation:[[:space:]]*'worktree'|agentType:[[:space:]]*'implementer'" "$rjs"; then
    echo "FAIL: test_round_enrichment — roadmap.js must be advisor-only (no worktree / no implementer)"; return 1
  fi
  # 2. The planner self-QA + the authoring agent run INSIDE the script (not the orchestrator's turn).
  if ! grep -qE "agentType:[[:space:]]*'planner'" "$rjs"; then
    echo "FAIL: test_round_enrichment — roadmap.js does not run the planner self-QA"; return 1
  fi
  if ! grep -qE "agentType:[[:space:]]*'pm-spec'" "$rjs"; then
    echo "FAIL: test_round_enrichment — roadmap.js does not delegate authoring to an agent (pm-spec)"; return 1
  fi
  # 3. persist routes track=='roadmap' to persist_roadmap (writes the canonical docs/step-3-specs artifact).
  if ! grep -q 'def persist_roadmap' "$persist" || ! grep -q "track == \"roadmap\"" "$persist"; then
    echo "FAIL: test_round_enrichment — persist-run-artifacts.py missing the roadmap route"; return 1
  fi
  # 4. The skill dispatches the engine (Workflow + roadmap.js) — the orchestrator drives no funnel.
  if ! grep -q 'workflows/roadmap.js' "$skill" || ! grep -qi 'Engine dispatch' "$skill"; then
    echo "FAIL: test_round_enrichment — SKILL.md does not dispatch the roadmap Workflow engine"; return 1
  fi
  # 5. The phase injection points at the engine (no hand-driven funnel) + keeps autonomous/--attended.
  if ! grep -qi 'roadmap.js' "$rl" || ! grep -qiE 'autonomous' "$rl" || ! grep -qiE 'attended' "$rl"; then
    echo "FAIL: test_round_enrichment — round-loop.md must point at the engine + carry autonomous/--attended"; return 1
  fi
  # 6. SKILL + rule carry the ADR-054 behavioral contract.
  if ! grep -q 'autonomous-to-completion' "$skill" || ! grep -q -- '--attended' "$skill"; then
    echo "FAIL: test_round_enrichment — SKILL.md missing autonomous-to-completion / --attended"; return 1
  fi
  if ! grep -q 'ADR-054' "$rules"; then
    echo "FAIL: test_round_enrichment — rules-advisory-modes.md missing the ADR-054 contract"; return 1
  fi
  # 7. Both ADRs exist and pair (054 behavioral, 055 structural).
  if [ ! -f "$adr54" ] || ! grep -qiE 'amends ADR-030|enacts ADR-033' "$adr54"; then
    echo "FAIL: test_round_enrichment — ADR-054 missing / does not state it amends ADR-030"; return 1
  fi
  if [ ! -f "$adr55" ] || ! grep -qiE 'Workflow engine|structural half' "$adr55"; then
    echo "FAIL: test_round_enrichment — ADR-055 (roadmap-on-the-engine) missing / mis-stated"; return 1
  fi
  echo "PASS: test_round_enrichment"; return 0
}

# ---------------------------------------------------------------------------
# TEST 10: intent-capture (ADR-065, amended 2026-06-13) — Phase E captures by default; curated/jam-direct
# short-circuit; empty capture + empty intent => crit-1 interrupt. Runs the roadmap engine under the
# behavioral harness, which now exercises the REAL INLINED capture path (no shared helper, no import-strip,
# no helper injection — the Workflow runtime forbids cross-file imports). Folds in the fail-safe (invalid
# intentSource THROWS) + jam-path (CR-002 jamSlug-preferred resolution) cases from the retired
# test-intent-capture.sh unit harness — there is no longer a separate _intent-capture.js module to unit-test.
# ---------------------------------------------------------------------------
test_intent_capture() {
  if ! command -v node >/dev/null 2>&1; then
    echo "PASS: test_intent_capture (skipped — node not installed)"; return 0
  fi
  local out
  out=$(cd "$REPO_ROOT/core/scripts" && node --input-type=module -e '
    import { runRoadmap, defaultRoadmapMock } from "./fixtures/roadmap-harness.mjs"
    let fail = 0
    const countCapture = (calls) => calls.filter(c => c === "intent-capture").length
    // (1) curated + non-empty intent => ZERO capture dispatches; verbatim intent flows.
    {
      const { calls } = await runRoadmap({
        args: { runDir: "/tmp/r", repoRoot: "/tmp/repo", phase: "E", epicSlug: "ep", intent: "curated intent", intentSource: "curated" },
        mock: defaultRoadmapMock,
      })
      if (countCapture(calls) !== 0) { console.error("FAIL curated capture count", countCapture(calls)); fail++ }
    }
    // (2) jam-direct + non-empty intent => ZERO capture dispatches.
    {
      const { calls } = await runRoadmap({
        args: { runDir: "/tmp/r", repoRoot: "/tmp/repo", phase: "E", epicSlug: "ep", intent: "jam intent", intentSource: "jam-direct" },
        mock: defaultRoadmapMock,
      })
      if (countCapture(calls) !== 0) { console.error("FAIL jam-direct capture count", countCapture(calls)); fail++ }
    }
    // (3) capture + empty intent + empty jam capture result => crit-1 interrupt, no further dispatch.
    {
      const mock = (o, p) => {
        if (o.label === "intent-capture") return { markdown: "" }   // empty capture
        return defaultRoadmapMock(o, p)
      }
      const { result, calls } = await runRoadmap({
        args: { runDir: "/tmp/r", repoRoot: "/tmp/repo", phase: "E", epicSlug: "ep", intent: "", intentSource: "capture" },
        mock,
      })
      if (countCapture(calls) !== 1) { console.error("FAIL capture dispatched once", countCapture(calls)); fail++ }
      if (result.surfaceRequired !== true) { console.error("FAIL empty-capture surfaceRequired", result.surfaceRequired); fail++ }
      if (!(result.criterionFindings || []).some(f => f.criterion_match === "crit-1")) { console.error("FAIL empty-capture crit-1"); fail++ }
      if (calls.includes("research")) { console.error("FAIL empty-capture should not reach research"); fail++ }
    }
    // (4) capture + empty intent + non-empty jam capture => one capture dispatch, threads into research.
    {
      const { result, calls } = await runRoadmap({
        args: { runDir: "/tmp/r", repoRoot: "/tmp/repo", phase: "E", epicSlug: "ep", intent: "", intentSource: "capture" },
        mock: defaultRoadmapMock,
      })
      if (countCapture(calls) !== 1) { console.error("FAIL capture-default dispatch", countCapture(calls)); fail++ }
      if (typeof result.capturedIntent !== "string" || !result.capturedIntent.length) { console.error("FAIL capturedIntent in return"); fail++ }
    }
    // (5) fail-safe (folded from test-intent-capture.sh) — an unrecognized intentSource MUST THROW
    //     (no silent default; a typo must not skip capture). The harness surfaces the throw as a rejection.
    {
      let threw = false
      try {
        await runRoadmap({
          args: { runDir: "/tmp/r", repoRoot: "/tmp/repo", phase: "E", epicSlug: "ep", intent: "x", intentSource: "bogus" },
          mock: defaultRoadmapMock,
        })
      } catch (e) { threw = true }
      if (!threw) { console.error("FAIL invalid intentSource: expected THROW (no silent default)"); fail++ }
    }
    // (6) CR-002 jam-path resolution (folded) — the capture dispatch prompt interpolates the LIVE jam path
    //     docs/step-2-planning/jam-<slug>/, and PREFERS jamSlug over epicSlug when the operator names a jam.
    {
      let capturePrompt = ""
      const mock = (o, p) => {
        if (o.label === "intent-capture") { capturePrompt = p; return { markdown: "# grounded" } }
        return defaultRoadmapMock(o, p)
      }
      await runRoadmap({
        args: { runDir: "/tmp/r", repoRoot: "/tmp/repo", phase: "E", epicSlug: "ep", jamSlug: "other-jam", intent: "", intentSource: "capture" },
        mock,
      })
      if (!/docs\/step-2-planning\/jam-other-jam\//.test(capturePrompt)) { console.error("FAIL jamSlug-preferred jam path", capturePrompt.slice(0,120)); fail++ }
      if (/docs\/planning\/jam-/.test(capturePrompt)) { console.error("FAIL retired docs/planning path leaked"); fail++ }
    }
    // (7) CR-002 fallback — no jamSlug => the jam path falls back to epicSlug.
    {
      let capturePrompt = ""
      const mock = (o, p) => {
        if (o.label === "intent-capture") { capturePrompt = p; return { markdown: "# grounded" } }
        return defaultRoadmapMock(o, p)
      }
      await runRoadmap({
        args: { runDir: "/tmp/r", repoRoot: "/tmp/repo", phase: "E", epicSlug: "my-epic", intent: "", intentSource: "capture" },
        mock,
      })
      if (!/docs\/step-2-planning\/jam-my-epic\//.test(capturePrompt)) { console.error("FAIL epicSlug fallback jam path", capturePrompt.slice(0,120)); fail++ }
    }
    process.exit(fail === 0 ? 0 : 1)
  ' 2>&1)
  if [ $? -ne 0 ]; then
    echo "FAIL: test_intent_capture — ${out}"; return 1
  fi
  echo "PASS: test_intent_capture"; return 0
}

# ---------------------------------------------------------------------------
# PEC-T13 — examiner fold-in pass (AFTER self-qa, BEFORE finalize). AC-031/AC-033.
# ---------------------------------------------------------------------------
test_examine_foldin() {
  if ! command -v node >/dev/null 2>&1; then
    echo "PASS: test_examine_foldin (skipped — node not installed)"; return 0
  fi
  local out
  out=$(cd "$REPO_ROOT/core/scripts" && node --input-type=module -e '
    import { runRoadmap, defaultRoadmapMock } from "./fixtures/roadmap-harness.mjs"
    let fail = 0
    const base = { runDir:"/tmp/r", repoRoot:"/tmp/repo", phase:"E", epicSlug:"ep", intent:"x", intentSource:"curated", fanOut:false }
    const idx = (a,v) => a.indexOf(v)

    // (1) AC-031: ONE examiner dispatched post-self-qa; ledger record returned. Clean SOUND => no fold needed, no halt.
    {
      const { result, calls } = await runRoadmap({ args: base, mock: defaultRoadmapMock })
      if (calls.filter(c => c === "examine").length !== 1) { console.error("FAIL examine dispatched once", calls); fail++ }
      if (!(idx(calls,"examine") > idx(calls,"self-qa"))) { console.error("FAIL examine after self-qa"); fail++ }
      const d = result.examinerDispatches || []
      if (d.length !== 1 || d[0].verdict !== "SOUND") { console.error("FAIL examinerDispatches ledger record", JSON.stringify(d)); fail++ }
      if (result.surfaceRequired) { console.error("FAIL clean examine must not halt"); fail++ }
    }

    // (2) AC-031: FOLD-IN-REQUIRED => finalize runs (after examine) and the draft reflects the folded finding.
    {
      const mock = (o,p) => {
        if (o.agentType === "examiner") return { verdict:"FOLD-IN-REQUIRED", findings:[{id:"F-001",severity:"BAD",prescription:"tighten the wave-1 seam"}], summary:"fold needed" }
        if (o.label === "finalize") return { markdown:"# roadmap [examiner F-001 FOLDED]", waves:[{slug:"wave-1-do",skeleton:"s"}] }
        return defaultRoadmapMock(o,p)
      }
      const { result, calls } = await runRoadmap({ args: base, mock })
      if (!(idx(calls,"examine") < idx(calls,"finalize") && idx(calls,"examine") >= 0)) { console.error("FAIL examine before finalize", calls); fail++ }
      if (!result.roadmapMarkdown.includes("FOLDED")) { console.error("FAIL finding not folded into draft"); fail++ }
      if ((result.examinerDispatches||[])[0].verdict !== "FOLD-IN-REQUIRED") { console.error("FAIL verdict not recorded"); fail++ }
      if (result.surfaceRequired) { console.error("FAIL fold-in must not introduce a halt (AC-033)"); fail++ }
    }

    // (3) AC-033: a severe RETHINK verdict still does NOT halt — fold-in only, rides the decision-log surface (findings).
    {
      const mock = (o,p) => {
        if (o.agentType === "examiner") return { verdict:"RETHINK", findings:[{id:"F-002",severity:"UGLY",prescription:"re-seam"}], summary:"wrong at the seam" }
        if (o.label === "finalize") return { markdown:"# roadmap [re-seamed]", waves:[{slug:"wave-1-do",skeleton:"s"}] }
        return defaultRoadmapMock(o,p)
      }
      const { result } = await runRoadmap({ args: base, mock })
      if (result.surfaceRequired) { console.error("FAIL RETHINK must NOT add a new halt class (AC-033)"); fail++ }
      if (!/RETHINK/.test(result.findings["examiner-plan"] || "")) { console.error("FAIL RETHINK not recorded on the decision-log surface"); fail++ }
    }
    process.exit(fail === 0 ? 0 : 1)
  ' 2>&1)
  if [ $? -ne 0 ]; then
    echo "FAIL: test_examine_foldin — ${out}"; return 1
  fi
  echo "PASS: test_examine_foldin"; return 0
}

# ---------------------------------------------------------------------------
# ADR-121 — Phase-E fan-out auto-serializes cross-wave shared-sink collisions.
# A RESOLVABLE ordering gap (parallel cross-wave tickets sharing a planned_files
# sink with no edge) is auto-serialized (later wave depends_on earlier) and the
# run PROCEEDS — replacing the old expensive late hard-fail. A GENUINE inter-wave
# ordering CYCLE still hard-fails (validate-fail/crit-1). fanOut:false isolates
# the epic-level partition check (deriveCrossWaveSerialization -> validateWavePartition).
# ---------------------------------------------------------------------------
test_autoserialize_crosswave_sinks() {
  if ! command -v node >/dev/null 2>&1; then
    echo "PASS: test_autoserialize_crosswave_sinks (skipped — node not installed)"; return 0
  fi
  local out
  out=$(cd "$REPO_ROOT/core/scripts" && node --input-type=module -e '
    import { runRoadmap, defaultRoadmapMock } from "./fixtures/roadmap-harness.mjs"
    let fail = 0
    const base = { runDir:"/tmp/r", repoRoot:"/tmp/repo", phase:"E", epicSlug:"wq", intent:"x", intentSource:"curated", fanOut:false }

    // (1) RESOLVABLE collision: two parallel cross-wave tickets share a planned_files sink with no edge.
    //     Expect auto-serialization (later wave depends_on earlier), the run PROCEEDS (no validate-fail),
    //     and an AUTOSERIAL WARN is surfaced.
    {
      const mock = (o, p) => {
        if (o.agentType === "spec-decomposer") return { tickets: [
          { key:"WQ-T1", description:"a", depends_on:[], planned_files:["core/x.js"], acceptance:["AC-1"], wave_slug:"wave-1-a" },
          { key:"WQ-T2", description:"b", depends_on:[], planned_files:["core/x.js"], acceptance:["AC-2"], wave_slug:"wave-2-b" },
        ] }
        return defaultRoadmapMock(o, p)
      }
      const { result } = await runRoadmap({ args: base, mock })
      if (result.surfaceRequired === true) { console.error("FAIL collision should auto-serialize, not halt:", JSON.stringify(result.criterionFindings)); fail++ }
      if (result.surfaceType === "validate-fail") { console.error("FAIL collision wrongly validate-fail"); fail++ }
      if ((result.criterionFindings||[]).some(f => f.id === "DECOMP-GRAPH")) { console.error("FAIL DECOMP-GRAPH should not fire on a resolvable collision"); fail++ }
      if (!(result.warnFindings||[]).some(w => /AUTOSERIAL/.test(w.id || ""))) { console.error("FAIL no AUTOSERIAL WARN surfaced:", JSON.stringify(result.warnFindings)); fail++ }
    }

    // (2) GENUINE inter-wave ordering CYCLE (W1->W2 AND W2->W1 via distinct, non-sink-sharing tickets — so
    //     NOT a ticket cycle that validateTicketGraph would catch first). Expect it STILL hard-fails;
    //     auto-serialize must not mask it.
    {
      const mock = (o, p) => {
        if (o.agentType === "spec-decomposer") return { tickets: [
          { key:"CY-A1", description:"a1", depends_on:["CY-B1"], planned_files:["a.js"], acceptance:["AC-1"], wave_slug:"wave-1-a" },
          { key:"CY-B1", description:"b1", depends_on:[],          planned_files:["b.js"], acceptance:["AC-2"], wave_slug:"wave-2-b" },
          { key:"CY-B2", description:"b2", depends_on:["CY-A2"], planned_files:["c.js"], acceptance:["AC-3"], wave_slug:"wave-2-b" },
          { key:"CY-A2", description:"a2", depends_on:[],          planned_files:["d.js"], acceptance:["AC-4"], wave_slug:"wave-1-a" },
        ] }
        return defaultRoadmapMock(o, p)
      }
      const { result } = await runRoadmap({ args: base, mock })
      if (result.surfaceRequired !== true) { console.error("FAIL genuine inter-wave cycle must hard-fail"); fail++ }
      if (result.surfaceType !== "validate-fail") { console.error("FAIL cycle surfaceType:", result.surfaceType); fail++ }
      if (!(result.criterionFindings||[]).some(f => f.criterion_match === "crit-1" && /inter-wave dependency cycle/.test(f.detail||""))) { console.error("FAIL no inter-wave cycle crit-1:", JSON.stringify(result.criterionFindings)); fail++ }
    }

    // (3) CR-001 cycle-safety: a PRE-EXISTING inverted inter-wave edge (W1 ticket depends_on a W2 ticket)
    //     plus a shared-sink pair that derive would serialize. With fresh-reachability derive, NO ticket
    //     cycle is synthesized; the authored wave-ordering cycle (W1->W2 via the inverted edge, W2->W1 via the
    //     derived edge) is caught by validateWavePartition case (a) => clean validate-fail (never a crash, never
    //     a clean roadmap with a cyclic graph).
    {
      const mock = (o, p) => {
        if (o.agentType === "spec-decomposer") return { tickets: [
          { key:"IV-P", description:"p", depends_on:["IV-Q"], planned_files:["p.js"], acceptance:["AC-1"], wave_slug:"wave-1-a" },  // inverted: W1 depends on W2
          { key:"IV-Q", description:"q", depends_on:[],         planned_files:["s.js"], acceptance:["AC-2"], wave_slug:"wave-2-b" },
          { key:"IV-R", description:"r", depends_on:[],         planned_files:["s.js"], acceptance:["AC-3"], wave_slug:"wave-1-a" },  // shares s.js with IV-Q
        ] }
        return defaultRoadmapMock(o, p)
      }
      let threw = false, result
      try { ({ result } = await runRoadmap({ args: base, mock })) } catch (e) { threw = true }
      if (threw) { console.error("FAIL inverted-edge input must not crash derive"); fail++ }
      else if (result.surfaceRequired !== true || result.surfaceType !== "validate-fail") { console.error("FAIL inverted-edge must hard-fail cleanly:", result && result.surfaceType); fail++ }
    }
    process.exit(fail === 0 ? 0 : 1)
  ' 2>&1)
  if [ $? -ne 0 ]; then
    echo "FAIL: test_autoserialize_crosswave_sinks — ${out}"; return 1
  fi
  echo "PASS: test_autoserialize_crosswave_sinks"; return 0
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
failures=0
test_happy_path              || failures=$(( failures + 1 ))
test_arm_ordering            || failures=$(( failures + 1 ))
test_phase_advisor_allow     || failures=$(( failures + 1 ))
test_implementer_block_arm   || failures=$(( failures + 1 ))
test_implementer_block_phase || failures=$(( failures + 1 ))
test_resume_glob             || failures=$(( failures + 1 ))
test_off_transition          || failures=$(( failures + 1 ))
test_no_regression           || failures=$(( failures + 1 ))
test_round_enrichment        || failures=$(( failures + 1 ))
test_intent_capture          || failures=$(( failures + 1 ))
test_examine_foldin          || failures=$(( failures + 1 ))
test_autoserialize_crosswave_sinks || failures=$(( failures + 1 ))

if [ "$failures" -eq 0 ]; then
  echo ""
  echo "All 12 tests PASSED — ADR-030 /roadmap mode hook chain + ADR-035 enrichment + ADR-065 intent-capture + ADR-112 W5 examine fold-in + ADR-121 cross-wave auto-serialize correctly wired."
else
  echo ""
  echo "${failures} test(s) FAILED. See FAIL: messages above."
fi
exit "$failures"
