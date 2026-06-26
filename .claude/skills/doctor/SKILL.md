---
description: "Infra health check — run after any change to core/ (synthetic tests, CLAUDE.md drift via --claude-md, hook health, ADR↔rules pairing, consumer staleness via --weekly). READ-ONLY: reports a verdict + action list, never mutates; use /upgrade to act on it. Triggers: '/doctor', 'infra health check', 'is the substrate healthy', 'check infra', 'CLAUDE.md audit', 'weekly maintenance'."
---

# /doctor — claude-infra health check (read-only)

Diagnose substrate health in one pass and report. This is the read-only partner to `/upgrade`
(which *acts* on the findings). Run it after editing anything under `core/`, or any time you want
to know "is the substrate healthy and distributed?" It **never** mutates the repo or any consumer —
it reports + recommends.

Design + rationale: `docs/decisions/ADR-034-infra-doctor-upgrade.md`. The CLAUDE.md audit (`--claude-md`)
and the weekly doc-staleness battery (`--weekly`) absorbed the former `/maintain-project-instructions` and
`/weekly-maintenance` skills (ADR-081) — see the flags below.

## Flags / modes

- **`/doctor`** (default) — the full health pass: Step 1 (mechanical engine) + Step 1b (parked-work harvest)
  + Step 1c (stale-tracking cross-check, READ-ONLY) + Step 2 (CLAUDE.md audit) + Step 4 (optimization-eval arm,
  config-driven detect-and-log) + Step 3 (consolidated verdict). Step 4 is part of the default pass — it is
  the ONE place /doctor writes besides the Step 1/Step 1c inbox-harvest reserved seam.
- **`/doctor --eval`** — run ONLY the Step 4 optimization-eval arm (skip the health pass): detect unfired
  levers, mis-calibrated thresholds, measurement gaps, and regressions over the telemetry ledgers, and
  auto-log each finding as one inbox ticket. Reads `core/config/doctor-eval-config.json`; writes only into
  `docs/step-1-ideas/needs-shaping/`.
- **`/doctor --claude-md`** — run ONLY the CLAUDE.md audit (Step 2 below). The absorbed
  `/maintain-project-instructions`: global-drift detection + project-specific staleness (paths, scripts,
  deps, imports). Read-only report; skips the mechanical engine run.
- **`/doctor --weekly`** — run the full default battery **plus** Step 2w (documentation-staleness +
  rules-file-coverage, the absorbed `/weekly-maintenance` doc checks). This is the **scheduled-task** form —
  point a Claude Desktop weekly task at it (see § Scheduled-task use).
- **`/doctor --tokens`** — the **Fable spend roll-up** (ADR-088 D4). Renders ONLY the Fable ledger
  (`docs/step-3-specs/_fable-spend.jsonl`) — spend this week (in+out), per-dispatch in_tokens median/max,
  dispatch count by target, and any `over_envelope` lines flagged. Skips the health pass; read-only;
  exits 0 with a friendly "no Fable spend recorded" when the ledger is absent/empty. The 30-second
  "monitor Fable like a hawk" check that pairs with the `/examine` examiner door. Independent of
  `measure-run.sh --per-agent` (which reconciles the same ledger via `attributionAgent` journals).

## Process

### Step 1 — Mechanical checks (the engine)

Run the read-only diagnostic engine and capture its full output:

```bash
# Substrate path resolves in both contexts (ADR-031): .claude/scripts in a consumer, core/scripts in claude-infra.
S=.claude/scripts; [ -d "$S" ] || S=core/scripts
bash "$S/infra-doctor.sh"
```

It performs the following checks and ends in a parseable `DOCTOR VERDICT:` line:
1. **Synthetic test suite** — every `core/scripts/test-*.sh` passes (substrate integrity).
2. **Hook health** — each `core/hooks/*.sh` parses (`bash -n`), is executable, and is *registered*
   (referenced in a settings file — including the canonical v2 template
   `core/config/global/settings.json` — or invoked by another hook; an unregistered hook never
   fires). Also flags *dead references*: a hook the canonical template registers but whose
   `core/hooks/` file is gone (a cut/renamed hook left wired — it silently fails to fire).
3. **ADR↔rules pairing** — uncommitted `core/rules/*.md` edits have a paired `docs/decisions/` change
   (the CLAUDE.md "ADR per binding-rule change" discipline).
4. **Consumer distribution** — registered consumer repos (`core/config/infra-consumers.json`) are not
   behind `core/`; surfaces the exact `setup.sh … --refresh` command for any that are.
5. **Rule↔engine drift** — flags any `core/rules/*.md` / `core/agents/*.md` still describing retired v1
   machinery (plan-steps / wave-manifest / `t-*`·`w-*` / single-wave-implementer) as live (SH-3).
6. **Rules-file bloat** — `wc -c core/rules/*.md`; WARN >36k, ISSUE >40k (the ~40k Claude Code perf
   threshold; T17).
7. **ADR-index freshness** — runs `python3 core/scripts/adr-index.py --check` against
   `docs/decisions/INDEX.md`. WARN-class (quality-of-life nudge, not a substrate failure that gates
   `--strict`); the regenerator is `python3 core/scripts/adr-index.py` (or, in a consumer, the
   substrate-aware equivalent under `.claude/scripts/`).
8. **Substrate inbox harvest (T17)** — runs `harvest-infra-deferrals.sh` (a read-only PULL: copies
   consumer deferrals tagged `target: claude-infra` into the local `docs/step-1-ideas/` inbox as DEFER-
   files — ADR-087) and reports "harvested N new". This is the ONE place /doctor writes — only into the
   `docs/step-1-ideas/` inbox, never into `core/`/source; the substrate stays untouched. The pile is what you point an agent at.
9. **Substrate drift lint** — `drift-lint.sh` (ADR-080 D4): self-referential/broken symlinks, hook
   registration both directions, rules-cited `core/` paths, model pins, doc-lifecycle root discipline, and
   **live stale stage-name PATH references in live-contract surfaces** — Check 8, SHR4-E2 / AC-018: greps the
   tracked tree for the pre-ADR-127 stage names used as a LIVE PATH (`docs/step-4-pipeline` / `docs/step-5-done`)
   and FAILs on any match in a live-contract surface (`core/**`, `setup.sh`, `switch-infra.sh`, `CLAUDE.md`,
   `docs/conventions/**`, runbooks), so a root-level stale reference can no longer ship green (FAIL-class). The
   path-qualified pattern ignores descriptive `(was step-4-pipeline)` annotations; the history/archival doc
   trees (`docs/decisions/`, `docs/step-1-ideas/`, `docs/step-2-planning/`, `docs/step-3-specs/`,
   `docs/step-5-pipeline/`, `docs/step-6-done/`, `docs/playbooks/`, person folders, generated indexes) are
   excluded — they legitimately cite where things WERE (the authoritative exclude set is the `drift-lint.sh`
   Check-8 comment block). Stale markers, dead arms (WARN-class).
10. **F9 / investigation-first advisory lints (ADR-126 D-4 + examiner F-004)** — two **ADVISORY** lints
   (always `WARN`-class, never blocking):
   - **Heuristic-class advisory.** The investigation-first discipline has a DETERMINISTIC floor (now
     hook-enforced by `require-investigation.sh` — an implementer-tier dispatch with zero prior Explore in
     the run ledger blocks) AND HEURISTIC classes (scope-slip, ambiguity) that are false-positive-prone
     (examiner F-004) and MUST NOT become blocking hooks. This lint surfaces the heuristic classes as
     advisory and asserts NO new `core/hooks/` script blocks on them.
   - **Prose-rule-without-script F9 lint (ADR-126 D-4).** Flags any skill carrying a prose decision-rule
     with no backing deterministic script — the signal of an un-migrated F9 surface (scriptify the
     deterministic floor, ADR-126 D-1). **Allowlists the D-3 ceiling skills** (`resolver`, `shape`,
     `examine`) which carry prose decision-rules by design (uncited disposition / thesis-fork resolution).

`ISSUE` = hard problem; `WARN` = soft (surfaced, doesn't fail). Note the engine's `DOCTOR VERDICT:`.

### Step 1b — Parked-work harvest (intra-repo, read-only — R2)

Sibling to step 7's cross-repo pull: this surfaces parked work stranded in *run-folder prose* that never
became a capture file ("deferred to a focused pass", "out of scope: …", "TODO:"). **Report-only — it writes
nothing**; the operator triages each candidate with `/defer`.

```bash
python3 "$S/harvest-parked-work.py"          # default: high-signal files modified within 14 days
# python3 "$S/harvest-parked-work.py" --all  # every dated run folder (broader, noisier)
```

Surface the count + the candidate list as a `WARN`-class advisory (never an `ISSUE` — it's a triage nudge,
not a health failure). The last stdout line `HARVEST-PARKED: C candidate(s) …` is the parseable summary.
Distinct from step 7: T17 *pulls already-formed* deferrals; this *forms candidates from prose*. Both honor
the no-auto-write ethos — this one never writes at all.

### Step 1c — Stale-tracking cross-check (intra-repo, READ-ONLY — W5)

A read-only reconciliation arm: it cross-checks the things the substrate *tracks as open* against
*shipped reality on disk*, and reports anything stale or orphaned. It absorbs the
audit-deferral-and-drop-actually-happens check — i.e. it verifies that an item the operator deferred or
dropped really MOVED on disk (an executed handoff is no longer in `step-5-pipeline/PENDING/`; a closed
run no longer sits in `step-5-pipeline/`; a `DEFER-`/`FOLLOWUP-` capture lives where location-is-status
says it should). It is a triage cross-check, not an action.

**CRITICAL READ-ONLY contract (binding).** This arm REPORTS ONLY. It performs NO `git mv`, NO `git add`,
NO Write to any tracked path, NO `os.makedirs`, NO `open(..., 'w')` — it never mutates the repo, an inbox
file, a run folder, or any consumer. The ONLY sanctioned write anywhere in this SKILL is the Step 4
eval-arm auto-log (a separate ticket/arm); THIS arm writes nothing. Surface its findings as `WARN`-class
advisories (a triage nudge), never an `ISSUE` (it is not a substrate failure). The operator triages each
candidate with `/defer`, `/sweep`, or `closeout-run.py`.

The cross-checks (all read-only — list and compare, never move):
1. **Open handoffs vs shipped reality** — list `docs/step-5-pipeline/PENDING/*`; for each, judge whether
   the work it describes has already shipped (its target files exist / its run folder has closed out). An
   executed handoff still parked in `PENDING/` is **stale** — it should have MOVED to
   `docs/step-6-done/handoffs/`. Report each stale handoff by name.
2. **Open runs vs close-out** — list dated run folders under `docs/step-5-pipeline/YYYY-MM-DD/`; a run
   whose `run-log.md` carries a `CLOSED:` line but still sits in `step-5-pipeline/` (not moved to
   `step-6-done/`) is **orphaned** — close-out did not complete its MOVE. Report each.
3. **Deferred/dropped item actually moved (absorbed check)** — for a sample of recent `DEFER-`/`FOLLOWUP-`
   captures and parked items, verify the file lives where location-is-status (ADR-087) dictates: a
   deferral in the `docs/step-1-ideas/` inbox (not still in a run folder's `findings/`), a parked item
   under a parked shelf. A deferral/drop recorded in prose but with no corresponding moved file is
   **unmoved** — report it as a candidate the operator should re-run `/defer` on.
4. **Specs vs build status** — list `docs/step-3-specs/<slug>/` wave specs; a locked wave spec with no
   corresponding built/closed run (and no in-flight run folder) is **orphaned** (planned-never-built or
   built-but-untracked). Report each as a triage candidate.

Surface a parseable summary line: `STALE-CHECK: H stale handoff(s), R orphaned run(s), D unmoved
deferral(s), S orphaned spec(s) — read-only; triage with /defer or closeout-run.py`. Fold the counts into
the Step 3 verdict as `WARN`-class. Status is conveyed by plain-text labels (`STALE`, `ORPHANED`,
`UNMOVED`) — no color-only or symbol-only signaling.

### Step 2 — CLAUDE.md audit (LLM judgment — the merged `--claude-md` section, absorbed `/maintain-project-instructions`)

The engine can't judge semantic drift. This section audits `CLAUDE.md` (this repo's reference doc — or the
project's CLAUDE.md in a consumer) for two staleness categories. It is the absorbed
`/maintain-project-instructions` logic; run it as Step 2 of the default pass, or alone via
`/doctor --claude-md`. Read-only — capture findings, do NOT fix.

**2a. Global-drift detection** (CLAUDE.md duplicating now-canonical rules content):
1. List `core/rules/*.md` (`.claude/rules/*.md` in a consumer); extract each file's `##` section headers.
2. Read `CLAUDE.md` and find sections that match/overlap rules content — section headers that mirror a rules
   header (e.g. "Nimble Routing Table", "Agent Routing", "Stop Point Enforcement", "Working Style"),
   duplicated routing/agent tables, behavioral rules already in a rules file.
3. For each duplicate, compare CLAUDE.md against the canonical rules file: identical / stale / conflicting,
   with the specific delta (missing rows, outdated agent names, removed gates). Recommended action: "Replace
   with pointer" or "Remove — already covered by the rules file".

**2b. Project-specific staleness** (CLAUDE.md content vs. the actual codebase):
- **File paths** — every file/dir path referenced in CLAUDE.md → does it exist? Report any that don't.
- **Scripts** — every `npm run <script>` (or referenced helper script) → present in `package.json` / on disk?
- **Dependencies** — libraries named in CLAUDE.md: NEVER-listed libs still absent; ALWAYS/pattern libs still
  installed. Report mismatches.
- **Import patterns** — `import … from <path>` examples → resolve to an existing source file?
- **Component / auth / routing inventory** — listed components exist; referenced auth hooks/contexts and the
  installed router match what CLAUDE.md describes.
- **ADR/decision inventory** — ADR rows in CLAUDE.md's tables match `docs/decisions/` reality.

Capture: # global-drift issues, # stale project-specific items, the top 3 findings. Do NOT fix — report.

### Step 2w — Documentation staleness + rules-file coverage (`--weekly` only — absorbed `/weekly-maintenance`)

**Runs only under `/doctor --weekly`.** The absorbed `/weekly-maintenance` doc-staleness battery (read-only):

1. **Documentation staleness** — find `.md` files under `docs/` (excluding `docs/step-5-pipeline/` run
   artifacts); for each, flag broken file-path references (paths to source files that don't exist) and broken
   internal doc links (`.md` references that don't resolve). Capture: # docs checked, # with broken refs, top
   issues.
2. **Rules-file coverage** — list `core/rules/*.md` (`.claude/rules/*.md` in a consumer); compare against the
   expected substrate set (and check for broken symlinks in a consumer:
   `find .claude/rules -type l ! -exec test -e {} \; -print`). Flag any missing rules file (may indicate
   `setup.sh --refresh` is needed).

Fold the findings into the Step 3 verdict (doc-staleness is WARN-class — a nudge, not a substrate failure).

### Step 4 — Optimization-eval arm (config-driven detect-and-log — W6)

A config-driven evaluation arm that watches the **telemetry ledgers** for optimization signals the substrate
should act on, and **auto-logs each finding as ONE inbox ticket**. It runs as a default-pass step (after the
CLAUDE.md audit, before the Step 3 verdict) and is the door named at Step 1c L98 as "the Step 4 eval-arm (a
separate ticket/arm)". Run it alone via `/doctor --eval`.

**CRITICAL detect-and-log contract (binding).** This arm **DETECTS and LOGS, NEVER mutates the levers it
reads**. It does NOT edit `core/config/doctor-eval-config.json` (read-only input), does NOT touch `core/` or
any source file, does NOT `git push` or `gh pr`. Its **ONLY sanctioned write** is one inbox ticket under
`docs/step-1-ideas/needs-shaping/` (the capture-at-bucket taxonomy — ADR-111). This is the second sanctioned
/doctor write alongside the Step 1 inbox harvest; everything else /doctor does (Step 1b, Step 1c, Step 2/2w)
remains read-only.

**Read the config (never write it).** Load the levers/thresholds from `core/config/doctor-eval-config.json`:

```bash
EVAL_CFG=core/config/doctor-eval-config.json    # READ-ONLY input — the arm never writes this path
[ -f "$EVAL_CFG" ] || { echo "EVAL: no doctor-eval-config.json — skipping optimization-eval"; }
```

**Reuse the existing roll-up shapes — author NO second parser.** The arm reads the two telemetry ledgers
through the **already-built roll-up seams** (no fresh `jq`/python aggregator is written here):

1. **Fable spend** — reuse the `--tokens` Fable roll-up: `bash "$S/infra-doctor.sh" --tokens` over
   `docs/step-3-specs/_fable-spend.jsonl`. Compare its spend (in+out this week), per-dispatch in_tokens
   median/max, and `over_envelope` flags against the `fable_spend` thresholds in the config.
2. **Run metrics** — reuse the `metrics-summary.sh --json` roll-up: `bash "$S/metrics-summary.sh" --json`
   over `docs/step-3-specs/_metrics.jsonl`. Compare its per-metric `{median, mean, n}` (including
   `duration_seconds`) against the `run_metrics` thresholds, and read the per-metric `n` against
   `measurement_gaps` (low `n` / high null-fraction = a measurement gap).
3. **Friction-telemetry roll-up** — fold friction in as a **friction-ledger roll-up that REUSES the
   `--tokens` roll-up shape** (the same line-tolerant ledger render) — NOT a new parser. It is one more
   read over the same shape, surfaced as a friction summary line.

Detect across the four lever classes the config enumerates: **unfired levers** (a ledger idle past
`*_max_idle_days`), **mis-calibrated thresholds** (a median over its `*_ceiling`), **measurement gaps**
(a metric `n` below `min_runs_for_signal` or null-fraction over `max_null_fraction`), and **regressions**
(a roll-up trending worse against a prior window). Status is conveyed by **plain-text labels** —
`OVER`, `STALE`, `GAP`, `REGRESSION` — no color-only or symbol-only signaling (consistent with the Step 1c
`STALE`/`ORPHANED` and `--tokens` text-token convention).

**Auto-log each finding as ONE inbox ticket (the single sanctioned write).** For each finding, write exactly
one file into `docs/step-1-ideas/needs-shaping/` (the on-conveyor default bucket; `mkdir -p` it lazily):

- **Path:** `docs/step-1-ideas/needs-shaping/<YYYY-MM-DD>-<slug>.md`. **Deferral-class** findings (a lever the
  operator should revisit later rather than act on now) carry the **`DEFER-` prefix** —
  `docs/step-1-ideas/needs-shaping/DEFER-<YYYY-MM-DD>-<slug>.md` — consistent with the `/idea` + `/defer`
  capture-at-bucket convention T17 landed (ADR-087). No other write target appears.
- **Slug** = the threshold-crossing condition lowercased to `[a-z0-9-]` (e.g. `fable-weekly-spend-over`,
  `run-duration-median-over`, `agent-dispatches-measurement-gap`).
- **Dedup-on-slug before writing (reuse the `/idea` uniquify-not-overwrite rule).** If a same-slug file
  already exists in `needs-shaping/`, **uniquify** (`-2`, `-3`, …) — **never overwrite**. So re-running
  `/doctor` does not pile up duplicate eval tickets for a still-true condition: the dedup check is performed
  on the slug before the write, exactly as `/idea` does (`idea/SKILL.md` — "uniquify the slug; never
  overwrite"). (For a condition that is still true from a prior run you may simply skip re-logging an
  identical open ticket; the binding rule is uniquify-not-overwrite at write time.)
- **Content** = the `/idea` README schema (spark, captured, source=`/doctor --eval`, area, why/value, rough
  size, notes) plus the observed value vs. the config threshold that fired it.

Use Bash + a heredoc (date resolved at write time via `date +%F`) or the Write tool with an explicitly
resolved date. The eval-arm **STAGES only** (it never commits, pushes, or opens a PR — shared-state floor,
ADR-105).

Fold the finding count into the Step 3 verdict as `WARN`-class (an optimization nudge, not a substrate
failure). Surface a parseable summary line:
`EVAL: U unfired, M mis-calibrated, G measurement-gap, R regression finding(s) → logged to docs/step-1-ideas/needs-shaping/`.

### Step 3 — Consolidated verdict

Synthesize one short report:
- **Engine verdict** (HEALTHY / WARNINGS (n) / ISSUES (n)) + each ISSUE/WARN one-linered.
- **Stale-tracking** summary (Step 1c — read-only: stale handoffs, orphaned runs, unmoved deferrals,
  orphaned specs; all `WARN`-class triage nudges).
- **CLAUDE.md audit** summary (Step 2: global drift + project-specific staleness).
- **Documentation staleness** summary (Step 2w — `--weekly` only: broken doc refs, rules-file coverage).
- **Optimization-eval** summary (Step 4 — unfired levers, mis-calibrated thresholds, measurement gaps,
  regressions; each auto-logged to `docs/step-1-ideas/needs-shaping/`; all `WARN`-class nudges).
- **Prioritized action list** — what to fix, each tagged `[/upgrade can do this]` (auto-fixable:
  chmod, refresh consumers, apply safe CLAUDE.md fixes) or `[manual]` (failing test, unregistered
  hook needing a settings edit, ADR needed).

End with a one-line bottom line: `Substrate: HEALTHY` or `Substrate: N issue(s), M warning(s) — run /upgrade or see the action list.`

## Scope

- **Read-only on `core/`/source.** Never edits `core/`/source, commits, pushes, or runs `setup.sh` — that is
  `/upgrade`'s job. The ONLY writes /doctor performs are inbox-only: the Step 1 substrate harvest and the
  Step 4 eval-arm auto-log, both scoped to `docs/step-1-ideas/` (never `core/`/source; the config it reads
  is never mutated). Both STAGE only — no commit, no push, no PR (shared-state floor, ADR-105).
- **Runs in the claude-infra repo** (needs `core/` + `setup.sh`). In a consumer project, validate the
  distributed substrate instead with `./setup.sh <project> --validate`.
- The engine excludes its own test (`test-infra-doctor.sh`) from Step 1 to avoid recursion.
- **Unwired-consumer self-check (T-010).** If `/doctor` is invoked **from an unwired consumer** cwd
  (a different git repo whose `.claude/agents` + `.claude/rules` are absent, where the script is
  reached via abs-path), the engine short-circuits with a friendly "this isn't the claude-infra repo
  — run `/onboard` to wire this repo into the substrate" pointer instead of running the substrate
  sections against the consumer (which would be nonsensical). The hard-exit is preserved. The
  **wired-consumer happy path is unchanged** (its `.claude/agents` + `.claude/rules` are present →
  the engine proceeds against the substrate as before; CI / `/upgrade` flows still work).

## Scheduled-task use (`--weekly` — absorbed from `/weekly-maintenance`)

`/doctor --weekly` is the recurring-maintenance form (preserves the former `/weekly-maintenance`
Desktop-scheduled-task use case). To run it automatically every week in **Claude Desktop**:

1. **Schedule** (sidebar) → **+ New task**.
2. **Prompt:** `/doctor --weekly`; **Frequency:** Weekly; **Permission mode:** Plan (read-only — `/doctor`
   never mutates source); **Working directory:** the claude-infra repo root (or a wired consumer root).
3. Each week a fresh session runs the full health battery + the doc-staleness checks and reports the
   consolidated verdict; you get a Desktop notification when it completes.

**Requirements:** Claude Desktop open and the machine awake at the scheduled time (a missed run catches up
once on wake). The report is read-only — review the verdict + action list and decide what to act on
(`/upgrade` for the auto-fixable items).
