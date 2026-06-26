# Synthetic consumer-project fixture

A disposable fake-consumer skeleton for testing claude-infra helpers and hooks from a consumer-project-shaped cwd.

## Why this exists

claude-infra's self-tests run from claude-infra's own cwd. Many helpers behave differently when invoked from a consumer project's cwd (path resolution, state file location, manifest paths). Past defects shipped under self-tests but failed in real consumer-project use; this fixture closed that gap.

This fixture is the regression guard.

## Use

```bash
bash core/scripts/test-consumer-project.sh
```

Run from claude-infra root. The driver:

1. Copies the fixture to a `mktemp -d` scratch dir.
2. `cd`s into the scratch dir (consumer-project-shape cwd).
3. Runs each helper-under-test from that cwd.
4. Asserts expected behavior.

## Layout

```
core/scripts/fixtures/consumer-project/
├── README.md                          (this file)
├── .claude/
│   └── settings.local.json            (minimal stub)
├── docs/
│   └── pipeline/
│       └── 2026-05-08/
│           └── 2200-WAVE-fixture/
│               └── wave-manifest.json (3-ticket synthetic)
├── src/.gitkeep
└── tests/.gitkeep
```

The `.claude/agent-memory/active-runs/` subdir is **not staged** in the fixture — `core/hooks/block-source-edits.sh` (active-runs guard, merged in v2 T2) blocks any `Edit|Write` matching that path pattern (including `.gitkeep` markers). The test driver creates the subdir on the fly via `mkdir -p` (Bash — not blocked) when it needs to write state files.

## Adding helper coverage

When a helper or hook changes, add a test case to `core/scripts/test-consumer-project.sh`. The fixture's `wave-manifest.json` covers most ticket-shape cases (3-ticket linear, with deps + carve-out); extend the manifest if a test needs more.

## Maintenance discipline

The fixture evolves with the substrate:

- When phase docs / agent prompts / hook contracts change in ways that affect helper invocation from consumer-project cwd, update the fixture.
- New helpers in `core/scripts/` should add coverage here.
- Wave E2 (CI gate) requires the test to pass on PR; failing tests block merge.

Per `docs/build-principles.md` P-015, fixture rot is a recurrence-watch concern — a 3rd instance of fixture-stale failure triggers a structural rework (likely versioning the fixture against substrate releases).
