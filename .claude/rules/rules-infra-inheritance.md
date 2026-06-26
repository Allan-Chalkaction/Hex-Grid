# Infrastructure Inheritance Rules

## Symlinked Files Are Read-Only in Projects

**HOOK-ENFORCED** — `infra-symlink-guard.sh` blocks edits to files symlinked from claude-infra.

Files in `.claude/agents/`, `.claude/skills/`, `.claude/commands/`, `.claude/rules/`, and `.claude/hooks/` that are **symlinked from claude-infra** must NOT be edited directly in the project. These files are managed centrally in `claude-infra` and distributed via `setup.sh`.

### How to detect inherited files

Inherited files are symlinks. Before editing any file under `.claude/`, check:
- If the file path resolves through a symlink to a `claude-infra` directory, it is inherited
- Files with `->` in `ls -la` output pointing to `claude-infra` are inherited

### What to do instead

When a change is needed to an inherited file:

1. **Stop.** Do not edit the file in the project.
2. **Tell the user:** "This file is inherited from claude-infra via symlink. Changes must be made in the claude-infra repo and re-distributed via `setup.sh`."
3. **Identify the source:** Report the claude-infra source path (e.g., `core/agents/implementer.md`, `core/rules/rules-git.md`)
4. **If the user says "override":** Proceed with the edit. The symlink will be replaced by a local file. Warn that this will diverge from the infrastructure baseline and future `setup.sh --refresh` runs may overwrite it.

### What IS safe to edit in projects

- `.claude/settings.local.json` — project-specific permissions and hooks
- `.claude/project-paths.sh` — project-specific path configuration
- `.claude/agent-memory/` — agent session state (auto-managed)
- `.claude/agent-context/` — project-specific agent context overlays (if not symlinked)
- `CLAUDE.md` — project-specific conventions
- `docs/` — all pipeline artifacts, specs, decisions

### Why this rule exists

Editing inherited files in a project creates silent drift. The project diverges from the infrastructure baseline without any record in claude-infra. When `setup.sh` runs again, the `safe_link()` function skips existing local files, so the drift persists invisibly. Other projects using the same infrastructure never receive the improvement or fix.
