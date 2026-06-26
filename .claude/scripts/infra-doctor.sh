#!/usr/bin/env bash
# infra-doctor.sh — read-only health diagnostic for the claude-infra substrate.
#
# Runs after any change to core/ (or on demand) to answer: "is the substrate
# healthy, and is it distributed?" It is the mechanical engine behind the
# /doctor and /upgrade skills. READ-ONLY w.r.t. the SUBSTRATE (core/) and all
# consumers — it never mutates source or any consumer repo. The sole write is
# section 7's harvest, which copies infra-tagged consumer deferrals into THIS
# repo's own docs/step-1-ideas/ inbox (T17, ADR-087). It reports + recommends; the
# skills decide what to act on.
#
# Usage:
#   bash core/scripts/infra-doctor.sh [--strict] [--quiet]
#     --strict  exit non-zero when any issue is found (for /upgrade gating + CI gate use)
#     --quiet   suppress per-item PASS lines; show only section headers + issues + verdict
#
# Output: sectioned report ending in a machine-parseable line:
#   DOCTOR VERDICT: HEALTHY
#   DOCTOR VERDICT: ISSUES (<n>)
#
# Checks (read-only):
#   1. Synthetic test suite      — every core/scripts/test-*.sh passes
#   2. Hook health               — core/hooks/*.sh parse (bash -n), are executable, are
#                                  registered, and the canonical settings template has no
#                                  dead hook references (registers only existing hooks)
#   3. ADR<->rules pairing        — uncommitted core/rules edits have a paired docs/decisions change
#   4. Consumer distribution     — registered consumer repos are not behind core/
#   9. Substrate drift lint      — drift-lint.sh (ADR-080 D4): symlinks, hook registration,
#                                  rule-cited paths, model pins (FAIL); stale markers, dead arms (WARN)
#
# Design + rationale: docs/decisions/ADR-034-infra-doctor-upgrade.md +
#   docs/decisions/ADR-080-deterministic-surfacing-capture-driftlint.md (§D4).

set -uo pipefail

# --- args ---
STRICT=false
QUIET=false
TOKENS=false
for a in "$@"; do
  case "$a" in
    --strict) STRICT=true ;;
    --quiet)  QUIET=true ;;
    --tokens) TOKENS=true ;;
    *) echo "infra-doctor: unknown arg '$a'" >&2; exit 2 ;;
  esac
done

# --- locate repo root (the dir containing core/ + setup.sh) ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Unwired-consumer self-check (T-010) ---
# When invoked from a non-infra cwd via an absolute path (the script lives in the substrate but the
# operator's cwd is a different repo that hasn't been wired), the script would proceed against the
# infra repo, which isn't what the operator asked for. Detect this BEFORE the cd, and short-circuit
# with a friendly "this isn't the claude-infra repo — run /onboard" pointer instead of the bare
# "not at a claude-infra root" line.
INVOKER_CWD="$(pwd -P)"
# An "unwired-consumer" cwd is: a different directory from $REPO_ROOT, and it does NOT carry the
# substrate ($INVOKER_CWD/.claude/agents + $INVOKER_CWD/.claude/rules absent). A wired consumer
# (those both present) is allowed to run /doctor against the substrate (existing behavior — CI /
# /upgrade flows depend on it; AC-045 enforces the wired-consumer happy path).
if [ "$INVOKER_CWD" != "$REPO_ROOT" ] && [ ! -d "$INVOKER_CWD/.claude/agents" ] && [ ! -d "$INVOKER_CWD/.claude/rules" ]; then
  # Only fire the friendly self-check when the invoker is in a git repo (otherwise we may be
  # in /tmp or similar where the message would be confusing).
  if git -C "$INVOKER_CWD" rev-parse --show-toplevel &>/dev/null; then
    cat <<EOF >&2
infra-doctor: this isn't the claude-infra repo — and this repo isn't wired into the substrate.
              Run \`/onboard\` to wire this repo into the substrate (skills are globally available,
              so /onboard works from an unwired consumer). After /onboard, you can run /doctor
              from the wired repo or from the claude-infra repo itself.
              See: core/skills/onboard/SKILL.md.
EOF
    exit 2
  fi
fi

cd "$REPO_ROOT" || { echo "infra-doctor: cannot cd to repo root" >&2; exit 2; }

if [ ! -d core ] || [ ! -f setup.sh ]; then
  echo "infra-doctor: not at a claude-infra root (no core/ + setup.sh at ${REPO_ROOT})." >&2
  echo "This diagnostic runs in the claude-infra repo. In a consumer project, validate symlinks with: ./setup.sh <project> --validate" >&2
  exit 2
fi

# ----------------------------------------------------------------------------
# --tokens — Fable spend roll-up (ADR-088 D4). A focused render of the Fable
# ledger docs/step-3-specs/_fable-spend.jsonl, NOT part of the health pass; it
# short-circuits and exits 0. The 30-second "monitor Fable like a hawk" check:
# spend this week (in+out), per-dispatch median/max in_tokens, dispatch count by
# target, and any over_envelope lines flagged. Read-only. jq parses the ledger;
# absent/empty ledger → a friendly "no Fable spend recorded" and exit 0.
if [ "$TOKENS" = true ]; then
  LEDGER="docs/step-3-specs/_fable-spend.jsonl"
  echo "=== Fable spend roll-up (${LEDGER}) ==="
  if [ ! -s "$LEDGER" ]; then
    echo "  no Fable spend recorded (ledger absent or empty — written on first examiner dispatch)."
    exit 0
  fi
  if ! command -v jq &>/dev/null; then
    echo "  jq unavailable — cannot parse the Fable ledger." >&2
    exit 2
  fi
  # "this week" = entries with ts within the last 7 days (lexical compare on the
  # ISO-8601 ts prefix vs the date 7 days ago; tolerant of a missing/old `date -d`
  # by falling back to all-time when the cutoff can't be computed).
  if CUTOFF="$(date -u -d '7 days ago' +%FT%TZ 2>/dev/null)"; then :; \
  elif CUTOFF="$(date -u -v-7d +%FT%TZ 2>/dev/null)"; then :; \
  else CUTOFF=""; fi

  # Line-tolerant parse (CR-001): fromjson? drops malformed lines BEFORE the
  # slurp, so one bad line cannot abort the whole roll-up.
  jq -R 'fromjson? // empty' "$LEDGER" 2>/dev/null | jq -rs --arg cutoff "$CUTOFF" '
    # keep only well-formed objects carrying a numeric in_tokens
    map(select(type == "object" and (.in_tokens | type) == "number")) as $all
    | ($all | length) as $total
    | (if $cutoff == "" then $all
       else ($all | map(select((.ts // "") >= $cutoff))) end) as $week
    | ($week | map(.in_tokens)  | add // 0) as $in_sum
    | ($week | map(.out_tokens // 0) | add // 0) as $out_sum
    | ($week | map(.in_tokens) | sort) as $ins
    | ($ins | length) as $n
    | (if $n == 0 then 0
       elif ($n % 2) == 1 then $ins[($n/2|floor)]
       else (($ins[$n/2 - 1] + $ins[$n/2]) / 2) end) as $median
    | ($ins | max // 0) as $maxin
    | "  dispatches: \($total) all-time, \($n) in the last 7 days" ,
      "  spend this week: \($in_sum) in + \($out_sum) out = \($in_sum + $out_sum) tokens" ,
      "  per-dispatch in_tokens (this week): median \($median), max \($maxin)" ,
      "  by target (this week):" ,
      ( $week | group_by(.target) | map("    \(.[0].target // "<none>"): \(length)") | .[] ) ,
      ( ($all | map(select(.over_envelope == true))) as $over
        | if ($over | length) == 0 then "  over_envelope: none flagged"
          else "  over_envelope: \($over | length) dispatch(es) flagged:" ,
               ( $over | map("    [\(.ts // "?")] target=\(.target // "?") in=\(.in_tokens) out=\(.out_tokens // 0)") | .[] )
          end )
  ' 2>/dev/null || {
    echo "  ledger present but not parseable as JSONL (malformed lines?) — inspect $LEDGER" >&2
    exit 2
  }
  exit 0
fi

ISSUES=0      # hard problems (gate --strict)
WARNINGS=0    # soft problems (surfaced, do not gate --strict)
note_issue() { ISSUES=$((ISSUES + 1)); echo "  ISSUE: $*"; }
note_warn()  { WARNINGS=$((WARNINGS + 1)); echo "  WARN:  $*"; }
note_ok()    { [ "$QUIET" = true ] || echo "  PASS:  $*"; }
section()    { echo ""; echo "=== $* ==="; }

# Settings files where hooks may be registered. The canonical v2 template
# (core/config/global/settings.json — what switch-infra.sh installs) is checked
# FIRST so the doctor validates the substrate's own intended registrations, not
# only whatever happens to be installed at ${HOME}/.claude (which may lag a
# pending switch). User-level + project settings follow.
CANONICAL_SETTINGS="core/config/global/settings.json"
SETTINGS_FILES=(
  "$CANONICAL_SETTINGS"
  "${HOME}/.claude/settings.json"
  "${HOME}/.claude/settings.local.json"
  ".claude/settings.json"
  ".claude/settings.local.json"
)
hook_is_registered() { # $1 = hook basename. Registered = referenced in a settings
  local base="$1" f                     # file OR invoked by another hook (indirect).
  for f in "${SETTINGS_FILES[@]}"; do
    [ -f "$f" ] || continue
    grep -q "$base" "$f" 2>/dev/null && return 0
  done
  # indirect: another hook script invokes it (helper / dispatched hook)
  grep -rq --include='*.sh' "$base" core/hooks/ 2>/dev/null \
    && [ "$(grep -rl --include='*.sh' "$base" core/hooks/ 2>/dev/null | grep -cv "/${base}$")" -gt 0 ] \
    && return 0
  return 1
}

# ----------------------------------------------------------------------------
section "1. Synthetic test suite (substrate integrity)"
# Run every test-*.sh except this engine's own test (recursion guard).
#
# WITHIN-RUN BATTERY CACHE (ADR-118 W5B, AC-030/031). The ~63-script battery is
# expensive; test-substrate-ops-wave.sh invokes this doctor ~11x, which without
# a cache re-runs the full battery each time (~690 nested runs — reads as hung).
# When the harness sets $INFRA_DOCTOR_BATTERY_CACHE to a tempfile, the FIRST
# doctor invocation in the run runs the battery and records its VERDICT (ran +
# failed counts AND the rendered ISSUE/PASS lines) into that marker; SUBSEQUENT
# invocations replay the cached verdict and skip re-running the ~63 scripts. The
# battery still executes exactly ONCE per harness run (coverage preserved,
# AC-031) and a cached FAILURE still surfaces as an ISSUE so DOCTOR VERDICT stays
# accurate. De-duplication, NOT removal. A bare doctor call (no env var) runs the
# battery as before — no cache, identical behavior. The cache file is $TMPDIR
# scratch the harness owns; the doctor stays READ-ONLY w.r.t. the substrate.
ran=0; failed=0
_battery_cache_hit=false
if [ -n "${INFRA_DOCTOR_BATTERY_CACHE:-}" ] && [ -s "$INFRA_DOCTOR_BATTERY_CACHE" ]; then
  # Cache HIT: replay the recorded verdict. Line 1 = "ran failed"; the remainder
  # is the rendered output to re-emit verbatim (ISSUE lines included).
  read -r ran failed < <(head -1 "$INFRA_DOCTOR_BATTERY_CACHE")
  tail -n +2 "$INFRA_DOCTOR_BATTERY_CACHE"
  # Re-apply the failure count so this doctor's ISSUES/verdict matches a fresh run.
  if [ "${failed:-0}" -gt 0 ]; then ISSUES=$((ISSUES + failed)); fi
  echo "  (battery verdict reused from this run's cache — ran once; AC-030/031)"
  _battery_cache_hit=true
fi
if [ "$_battery_cache_hit" = false ]; then
  # Cache MISS (or no cache env var): run the full battery once. Stream a progress
  # header so a multi-second battery never reads as a hang.
  echo "  running synthetic test battery (core/scripts/test-*.sh)..."
  _battery_out=""
  for t in core/scripts/test-*.sh; do
    [ -f "$t" ] || continue
    base="$(basename "$t")"
    [ "$base" = "test-infra-doctor.sh" ] && continue        # excluded — it invokes this engine
    [ "$base" = "test-substrate-ops-wave.sh" ] && continue   # excluded — wave-end harness invokes this engine
    ran=$((ran + 1))
    if out=$(bash "$t" 2>&1); then
      # PASS line (suppressed under --quiet, mirroring note_ok). Build the line
      # directly rather than via note_ok so the cache-miss accounting is explicit.
      if [ "$QUIET" = true ]; then _line=""; else _line="  PASS:  $base"; fi
    else
      failed=$((failed + 1))
      ISSUES=$((ISSUES + 1))   # mirrors note_issue (which we cannot call in a subshell — its counter bump would be lost)
      _line="  ISSUE: $base failed — last lines:
$(echo "$out" | tail -4 | sed 's/^/        /')"
    fi
    [ -n "$_line" ] && { echo "$_line"; _battery_out="${_battery_out}${_line}"$'\n'; }
  done
  # Record the verdict to the run cache so later doctor calls in this run reuse it.
  if [ -n "${INFRA_DOCTOR_BATTERY_CACHE:-}" ]; then
    { echo "$ran $failed"; printf '%s' "$_battery_out"; } > "$INFRA_DOCTOR_BATTERY_CACHE" 2>/dev/null || true
  fi
fi
if [ "$failed" -gt 0 ]; then echo "  ${failed}/${ran} synthetic test script(s) failing (see ISSUE lines above)"; else echo "  ${ran} test scripts ran, all green"; fi

# ----------------------------------------------------------------------------
section "2. Hook health (syntax + executable + registration)"
hk=0; hk_bad=0; hk_unreg=0
for h in core/hooks/*.sh; do
  [ -f "$h" ] || continue
  hk=$((hk + 1))
  base="$(basename "$h")"
  problem=""
  bash -n "$h" 2>/dev/null || problem="syntax error (bash -n)"
  [ -x "$h" ] || problem="${problem:+$problem; }not executable (chmod +x)"
  if [ -n "$problem" ]; then hk_bad=$((hk_bad + 1)); note_issue "$base — $problem"; else note_ok "$base"; fi
  # Registration: a hook that isn't referenced in any settings file never fires.
  # Soft WARN (some scripts under core/hooks/ may be helpers, not registered hooks).
  if ! hook_is_registered "$base"; then
    hk_unreg=$((hk_unreg + 1))
    note_warn "$base — not referenced in any settings file (won't fire; wiring gap, or it's a helper). Settings checked: ${SETTINGS_FILES[*]}"
  fi
done
echo "  ${hk} hook script(s) checked${hk_bad:+, ${hk_bad} broken}${hk_unreg:+, ${hk_unreg} unregistered}"

# Dead-reference check: every infra hook the canonical template registers must
# have a backing file under core/hooks/. (A stale registration of a cut/renamed
# hook silently fails to fire — the inverse of the unregistered-hook check.)
# Only validates .claude/hooks/<name> references (the infra-managed dir); external
# paths like .mission-control/hooks/ are not infra-owned and are skipped.
if [ -f "$CANONICAL_SETTINGS" ]; then
  dead=0
  while IFS= read -r ref; do
    rb="${ref##*/}"
    [ -z "$rb" ] && continue
    if [ ! -e "core/hooks/$rb" ]; then
      dead=$((dead + 1))
      note_issue "$CANONICAL_SETTINGS registers '.claude/hooks/$rb' but core/hooks/$rb does not exist (dead reference — won't fire)."
    fi
  done < <(grep -oE '\.claude/hooks/[A-Za-z0-9._-]+' "$CANONICAL_SETTINGS" 2>/dev/null | sort -u)
  [ "$dead" -eq 0 ] && note_ok "canonical settings ($CANONICAL_SETTINGS): no dead hook references"
fi

# ----------------------------------------------------------------------------
section "3. ADR<->rules pairing (authoring discipline — CLAUDE.md)"
# Discipline: every change to core/rules/*.md pairs with a docs/decisions ADR.
# Check the WORKING TREE (uncommitted + staged) so this fires before commit.
rules_changed=$(git status --porcelain -- core/rules/ 2>/dev/null | awk '{print $NF}' | grep -E '\.md$' || true)
adr_changed=$(git status --porcelain -- docs/decisions/ 2>/dev/null | awk '{print $NF}' | grep -E '\.md$' || true)
if [ -n "$rules_changed" ]; then
  if [ -n "$adr_changed" ]; then
    note_ok "core/rules edits present AND a docs/decisions change is present (pairing plausible — verify the ADR covers it)"
  else
    note_issue "core/rules/*.md changed in the working tree but NO docs/decisions/*.md change — the 'ADR per binding-rule change' discipline (CLAUDE.md) wants a paired ADR. Files:"
    echo "$rules_changed" | sed 's/^/        /'
  fi
else
  note_ok "no uncommitted core/rules changes (nothing to pair)"
fi
echo "  rules/ADR pairing checked"

# ----------------------------------------------------------------------------
section "4. Consumer distribution (registered repos behind core/?)"
REG="core/config/infra-consumers.json"
if [ ! -f "$REG" ]; then
  echo "  no consumer registry (${REG}) — distribution check skipped. Add it to track consumer repos."
else
  # Registry schema: {"consumers": [{"path": "/abs/path", "label": "name"}]}
  count=$(jq -r '.consumers | length' "$REG" 2>/dev/null || echo 0)
  if [ "${count:-0}" -eq 0 ]; then
    echo "  consumer registry present but empty — add consumer repo paths to track distribution."
  fi
  i=0
  while [ "$i" -lt "${count:-0}" ]; do
    cpath=$(jq -r ".consumers[$i].path" "$REG" 2>/dev/null)
    clabel=$(jq -r ".consumers[$i].label // .consumers[$i].path" "$REG" 2>/dev/null)
    i=$((i + 1))
    [ -z "$cpath" ] && continue
    # expand a leading ~
    cpath_exp="${cpath/#\~/$HOME}"
    if [ ! -d "$cpath_exp/.claude" ]; then
      note_issue "${clabel}: ${cpath} has no .claude/ (never set up?) — run: ./setup.sh ${cpath} --refresh"
      continue
    fi
    # Count core/ files lacking a same-named entry under the consumer's .claude/<dir>.
    behind=0; missing_examples=""
    for d in agents skills commands rules hooks scripts config gate-prompts reference; do
      [ -d "core/$d" ] || continue
      while IFS= read -r f; do
        rel="${f#core/$d/}"
        if [ ! -e "$cpath_exp/.claude/$d/$rel" ]; then
          behind=$((behind + 1))
          [ -z "$missing_examples" ] && missing_examples="$d/$rel"
        fi
      done < <(find "core/$d" -type f 2>/dev/null)
    done
    if [ "$behind" -gt 0 ]; then
      note_issue "${clabel}: ${behind} core/ item(s) not distributed (e.g. ${missing_examples}) — run: ./setup.sh ${cpath} --refresh"
    else
      note_ok "${clabel}: distribution current"
    fi
  done
fi

# ----------------------------------------------------------------------------
section "5. Rule<->engine drift (retired v1 machinery in live rules/agents)"
# SH-3 scope 6: flag any core/rules/*.md or core/agents/*.md that still describes
# retired v1 phase-machine machinery as if it were live. The v2 engine (ADR-039/040)
# has no plan-steps.json, no wave-manifest.json-as-source-of-truth, no t-*/w-* phases,
# no spec-decomposer->plan-steps flow, no single-wave-implementer contract, and
# /pipeline + /adhoc are retired doors. A LIVE description of any of these is drift.
#
# False-positive guard: a hit is only drift if its LINE does NOT also carry a
# retirement marker (retired/dormant/legacy/superseded/frozen/deleted/historical/
# v1/no longer/gone/removed/dead/not the live/drift). That lets a rule correctly
# DOCUMENT the retirement (as SH-2 did) without tripping the check.
#
# NOTE (ADR-062/063): "one implementer per wave" / "NEVER a second implementer" are
# NO LONGER retired tokens — ADR-062 REVIVES the one-implementer-per-wave doctrine as
# the live build model (ADR-028's intent revived; implemented by ADR-063's engine
# rearchitecture). They were removed from DRIFT_TOKENS on the v2-build→main merge.
# The retained "single .?wave-implementer" token still catches the genuinely-superseded
# v1 *agent contract* (the `wave-implementer` agent is now a context-exhaustion fallback).
DRIFT_TOKENS='plan-steps\.json|wave-manifest\.json|\bt-implement\b|\bt-commit\b|\bw-setup\b|\bw-finalize\b|spec-decomposer .*plan.step|single .?wave-implementer'
# A line is NOT drift if it carries a retirement marker OR is a correct NEGATION of
# the v1 token (e.g. "there is no plan-steps.json", "not a hook-gated plan-steps").
RETIRE_MARKER='retired|dormant|legacy|supersede|frozen|deleted|historical|\bv1\b|no longer|gone|removed|\bdead\b|not the live|drift|absent|note:|source-of-truth|no .?plan-steps|no .?wave-manifest|not a hook-gated|not an? orchestrator-authored|no per-step|no atom|no spec-decomposer'
# Agents intentionally excluded: their v1 description is correct-by-definition and
# their realign is owned elsewhere — spec-decomposer (its tickets[] output realign is
# owned by its own def) and wave-implementer (the ADR-028 context-exhaustion fallback
# that legitimately reads wave-manifest.json). spec-conformance was realigned in the
# T15 sibling ticket (ADR-047 §2) and is now swept like any other live agent.
drift_hits=0
for f in core/rules/*.md core/agents/*.md; do
  [ -f "$f" ] || continue
  case "$f" in
    */spec-decomposer.md) continue ;;  # output realign owned by its own def; excluded from the v1-token sweep
    */wave-implementer.md) continue ;;                 # ADR-028 fallback; legitimately uses wave-manifest.json
  esac
  # lines matching a v1 token but NOT a retirement marker (case-insensitive)
  bad=$(grep -nEi "$DRIFT_TOKENS" "$f" 2>/dev/null | grep -vEi "$RETIRE_MARKER" || true)
  if [ -n "$bad" ]; then
    drift_hits=$((drift_hits + 1))
    note_issue "$f describes retired v1 machinery as live (no retirement marker on the line):"
    echo "$bad" | sed 's/^/        /'
  fi
done
[ "$drift_hits" -eq 0 ] && note_ok "no live rule/agent describes retired v1 machinery (plan-steps / wave-manifest / t-*·w-* / single-wave-implementer)"

# ----------------------------------------------------------------------------
section "6. Rules-file bloat (Claude Code ~40k perf threshold)"
# CLAUDE.md authoring discipline: a rules file past ~40k chars degrades Claude Code
# performance. WARN at 36k (approaching), ISSUE at 40k (over). T17.
for rf in core/rules/*.md; do
  [ -f "$rf" ] || continue
  bytes=$(wc -c < "$rf" | tr -d ' ')
  if [ "${bytes:-0}" -gt 40000 ]; then
    note_issue "$(basename "$rf"): ${bytes} chars — OVER the ~40k threshold; split or thin it."
  elif [ "${bytes:-0}" -gt 36000 ]; then
    note_warn "$(basename "$rf"): ${bytes} chars — approaching the ~40k threshold; consider thinning."
  fi
done
[ "$ISSUES" -ge 0 ] && note_ok "rules-file sizes checked (warn >36k, fail >40k)"

# ----------------------------------------------------------------------------
section "7. ADR-index freshness (docs/decisions/INDEX.md generated by adr-index.py)"
# Surface staleness in the generated ADR index. Posture is WARN (a stale generated
# doc is a freshness nuisance, not a substrate failure that should gate --strict).
# Mirrors the harvest-section invocation shape: call a script, parse its summary,
# emit per-result.
ADR_INDEX_SCRIPT="core/scripts/adr-index.py"
if [ -f "$ADR_INDEX_SCRIPT" ] && command -v python3 &>/dev/null; then
  if aout="$(python3 "$ADR_INDEX_SCRIPT" --check 2>&1)"; then
    note_ok "ADR index current — ${aout}"
  else
    # The script emits its message to stderr (captured into $aout via 2>&1); surface as WARN.
    msg="$(printf '%s' "$aout" | tail -1)"
    note_warn "ADR index stale: ${msg:-run \`python3 core/scripts/adr-index.py\` to regenerate}"
  fi
else
  note_warn "ADR-index script not found or python3 unavailable (skipped) — expected at ${ADR_INDEX_SCRIPT}"
fi

# ----------------------------------------------------------------------------
section "8. Substrate inbox — cross-repo infra flow-back harvest (T17)"
# Pull infra-tagged deferrals from registered consumers into claude-infra's OWN
# docs/step-1-ideas/ inbox (ADR-087). READ-ONLY w.r.t. consumers + the substrate
# (core/) — it writes ONLY into the docs/step-1-ideas/ inbox. Reports the count.
HARVEST_SCRIPT="core/scripts/harvest-infra-deferrals.sh"
if [ -x "$HARVEST_SCRIPT" ] || [ -f "$HARVEST_SCRIPT" ]; then
  hout="$(bash "$HARVEST_SCRIPT" 2>/dev/null | tail -1)"
  case "$hout" in
    HARVEST:*)
      hnew="$(printf '%s' "$hout" | sed -E 's/^HARVEST: ([0-9]+) new.*/\1/')"
      if [ "${hnew:-0}" -gt 0 ]; then
        note_ok "harvested ${hnew} new infra note(s) from registered consumers — see docs/step-1-ideas/DEFER-* (harvested-from stamp)"
      else
        note_ok "substrate inbox current (${hout#HARVEST: })"
      fi
      ;;
    *) note_warn "harvest produced no parseable summary (skipped)" ;;
  esac
else
  note_warn "harvest script not found ($HARVEST_SCRIPT)"
fi

# ----------------------------------------------------------------------------
section "9. Substrate drift lint (ADR-080 D4 — drift-lint.sh)"
# Deterministic drift detection: self-referential/broken symlinks, hook
# registration (both directions), rules-cited core/ paths that don't exist,
# model-pin allowlist (FAIL classes); stale delete-after markers + dead track
# arms (WARN classes). FAIL-class findings fold into ISSUES (gate --strict);
# WARN-class fold into WARNINGS.
DRIFT_LINT_SCRIPT="core/scripts/drift-lint.sh"
if [ -f "$DRIFT_LINT_SCRIPT" ]; then
  dlout="$(bash "$DRIFT_LINT_SCRIPT" --quiet 2>&1)"; dlrc=$?
  dlsummary="$(printf '%s' "$dlout" | grep -E '^DRIFT-LINT:' | tail -1)"
  # Surface each WARN/FAIL line from drift-lint under the doctor's own tallies.
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      *"  FAIL: "*) note_issue "drift-lint: ${line#*FAIL: }" ;;
      *"  WARN: "*) note_warn  "drift-lint: ${line#*WARN: }" ;;
    esac
  done < <(printf '%s\n' "$dlout" | grep -E '  (WARN|FAIL): ')
  if [ "$dlrc" -eq 0 ]; then
    note_ok "drift-lint clean — ${dlsummary:-DRIFT-LINT: PASS}"
  else
    # FAIL lines were already counted into ISSUES above; this just surfaces the summary.
    echo "  ${dlsummary:-DRIFT-LINT: FAIL}"
  fi
else
  note_warn "drift-lint script not found ($DRIFT_LINT_SCRIPT)"
fi

# ----------------------------------------------------------------------------
section "10. F9 / investigation-first advisory lints (ADR-126 D-4 + examiner F-004)"
# READ-ONLY advisory lints (never blocking — they print recommendations, never gate
# beyond the WARN tally). Two lints land here:
#
#  (a) HEURISTIC-CLASS advisory (examiner F-004). The investigation-first discipline
#      has a DETERMINISTIC floor (now enforced by require-investigation.sh) AND
#      HEURISTIC classes (scope-slip, ambiguity) that are false-positive-prone and
#      MUST NOT become blocking hooks. This lint reminds the operator those classes
#      stay advisory — and asserts no NEW blocking hook was authored for them.
#
#  (b) PROSE-RULE-WITHOUT-SCRIPT lint (ADR-126 D-4). Flag any skill that carries a
#      prose decision-rule with no backing deterministic script — the signal of an
#      un-migrated F9 surface. ALLOWLISTS the D-3 ceiling paths (resolver-uncited,
#      shape/thesis-fork) which carry prose decision-rules BY DESIGN.

# (a) Heuristic-class advisory + the no-new-blocking-hook assertion.
# The deterministic floor IS a blocking hook (require-investigation.sh, by design).
# The heuristic classes must NOT be — assert no core/hooks/ script blocks on them.
HEURISTIC_HOOK_HITS=$(grep -rliE 'scope.?slip|ambiguity' core/hooks/ 2>/dev/null \
  | grep -v 'require-investigation.sh' || true)
if [ -n "$HEURISTIC_HOOK_HITS" ]; then
  # A hook file references the heuristic classes. Only an ISSUE if it BLOCKS on them
  # (exit 2 tied to the class) — a comment that explains the EXCLUSION is fine. We
  # advise review rather than hard-fail (the doctor is advisory here).
  note_warn "F9/heuristic: hook file(s) reference scope-slip/ambiguity — confirm they only DOCUMENT the exclusion, never BLOCK on these false-positive-prone classes (examiner F-004): $(echo "$HEURISTIC_HOOK_HITS" | tr '\n' ' ')"
else
  note_ok "F9/heuristic: no hook blocks on the heuristic classes (scope-slip/ambiguity stay /doctor advisory — examiner F-004)"
fi
echo "  ADVISORY: scope-slip / ambiguity are false-positive-prone (examiner F-004) — they are surfaced here as advisory lint, NEVER as blocking hooks. Only the deterministic investigation-first floor (zero prior Explore on an implementer dispatch) is hook-enforced (require-investigation.sh)."

# (b) Prose-rule-without-script F9 lint (ADR-126 D-4). Scan each SKILL.md for a
# prose decision-rule signature (a phrase that decides a verdict/route/placement by
# prose) and WARN when the skill has no co-located backing script reference. The
# D-3 ceiling skills are allowlisted (they carry prose decision-rules by design).
# Heuristic + advisory by construction — a WARN, never an ISSUE.
F9_CEILING_ALLOWLIST='resolver|shape|examine'   # D-3 ceiling: uncited disposition, thesis-fork resolution
# Prose-decision signature: a skill that says it "decides"/"classifies"/"routes by
# judgment" a verdict/placement. Kept conservative to avoid noise.
F9_PROSE_SIG='decide(s)? by (judgment|reading)|classif(y|ies) .* by (judgment|reading)|prose (decision-)?rule|verdict (by|via) (judgment|inference)'
f9_flagged=0
for sk in core/skills/*/SKILL.md; do
  [ -f "$sk" ] || continue
  skill_name="$(basename "$(dirname "$sk")")"
  # Allowlist the D-3 ceiling skills (prose decision-rules by design):
  # resolver-uncited disposition, /shape + /examine thesis-fork resolution.
  echo "$skill_name" | grep -qE "^(${F9_CEILING_ALLOWLIST})$" && continue
  # Does the skill carry a prose decision-rule signature?
  if grep -qiE "$F9_PROSE_SIG" "$sk" 2>/dev/null; then
    # Does it reference ANY backing deterministic script (a .py/.sh shell-out)?
    if ! grep -qE '\.(py|sh)\b' "$sk" 2>/dev/null; then
      f9_flagged=$((f9_flagged + 1))
      note_warn "F9-lint (ADR-126 D-4): skill '${skill_name}' carries a prose decision-rule but references NO backing deterministic script — candidate un-migrated F9 surface (scriptify the deterministic floor, or confirm it is irreducible ceiling)."
    fi
  fi
done
[ "$f9_flagged" -eq 0 ] && note_ok "F9-lint: no skill carries a prose decision-rule lacking a backing script (D-3 ceiling skills allowlisted: ${F9_CEILING_ALLOWLIST})"

# ----------------------------------------------------------------------------
echo ""
echo "============================================================"
if [ "$ISSUES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  echo "DOCTOR VERDICT: HEALTHY"
  exit 0
elif [ "$ISSUES" -eq 0 ]; then
  echo "DOCTOR VERDICT: WARNINGS (${WARNINGS})"
  exit 0
else
  echo "DOCTOR VERDICT: ISSUES (${ISSUES}), WARNINGS (${WARNINGS})"
  [ "$STRICT" = true ] && exit 1
  exit 0
fi
