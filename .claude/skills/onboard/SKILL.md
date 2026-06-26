---
name: onboard
description: Wire a new repo into the claude-infra substrate in one command — runs setup.sh and registers the repo in infra-consumers.json. Use when standing up a fresh project, or when a repo isn't infra-wired. Triggers - "/onboard", "onboard this repo", "register this repo", "set up infra here", "wire this project".
user_invocable: true
---

# /onboard — wire + register a repo into the substrate (one command)

Standing up a new repo against claude-infra is two manual steps that are easy to forget:
1. `setup.sh <repo>` — symlink `core/*` into the repo's `.claude/` and register the guard hooks.
2. Add the repo to `core/config/infra-consumers.json` — so `/doctor` tracks it for drift, `/upgrade`
   refreshes it, and T17 harvest can see it.

`/onboard` does **both** in one shot, idempotently. Run it from inside the new repo (or pass a path).

> **Why this works in an un-wired repo:** skills live in `core/skills/`, which `~/.claude/skills`
> symlinks to wholesale — so `/onboard` is **globally available in every session**, including a brand-new
> repo that has never run `setup.sh`. No chicken-and-egg.

## Usage

- `/onboard` — wire + register the **current** repo (cwd).
- `/onboard <path>` — wire + register the repo at `<path>`.
- `/onboard [path] --stacks react,typescript,supabase,…` — pass a stack list through to `setup.sh`
  (optional; omit for core-only wiring; stacks can be added later by re-running with `--stacks`).

## On invocation

1. **Resolve the infra repo root** (works from any repo):
   ```bash
   INFRA_ROOT="$(cd "$(dirname "$(readlink "$HOME/.claude/skills")")/.." && pwd)"
   ```
   (`~/.claude/skills` → `<infra-repo>/core/skills`; two `dirname`s up = the infra repo root. This is the
   currently-active substrate per `switch-infra.sh`.)

2. **Resolve the target repo:** the path arg if given, else `pwd`. Confirm it exists and is a git repo
   (`git -C <target> rev-parse` succeeds) — if it isn't a git repo, say so and ask before proceeding
   (wiring a non-repo is almost never intended). Refuse if the target **is** the infra repo itself.

3. **Wire it** — run `setup.sh` (pass `--stacks` through if the user supplied one):
   ```bash
   bash "$INFRA_ROOT/setup.sh" "<target>" [--stacks <list>]
   ```
   This is re-runnable; on an already-wired repo it relinks/validates (use `--refresh` only if the user
   explicitly wants templates re-copied).

4. **Register it** — idempotent registry append:
   ```bash
   bash "$INFRA_ROOT/core/scripts/register-consumer.sh" "<target>" [<label>]
   ```
   Default `<label>` = the repo's basename. Already-present → no-op. Read the last `REGISTER:` line for the
   outcome (`added` / `already-present` / `error`).

5. **Confirm** — a tight summary: what `setup.sh` reported (core/stack symlinks, any broken), the
   `REGISTER:` outcome, and the standard setup next-steps (fill `.claude/project-paths.sh`, write the
   project's `CLAUDE.md`). If `setup.sh` reported broken symlinks or a hook-registration warning, surface
   that — don't bury it.

## Guardrails

- **Idempotent + safe to re-run.** Both steps no-op cleanly on an already-onboarded repo.
- **Operator-authority action, run on explicit invocation.** `/onboard` wires + registers only when
  invoked; nothing here auto-mutates a repo in the background.
- **Never registers the infra repo itself.** `register-consumer.sh` refuses it.
- **Does not commit or push.** The registry edit lands in the infra repo's working tree; the operator
  commits it (it's a tracked config change). Mention that in the confirmation.
- **Scope:** this skill only runs `setup.sh` + `register-consumer.sh` against the target. It does not
  edit application source or distribute to other consumers (that's `/upgrade`).
