---
name: generate-skill-doc
description: Use when the user asks to "bootstrap a skill", "generate a SKILL.md", "create skill documentation", or needs to scaffold a new skill following Anthropic's canonical patterns.
allowed-tools: Read, Write, Glob, Grep, Bash
---

# Generate Skill Documentation

Read `core/skills/skill-development/SKILL.md` for the canonical skill structure, writing style, and validation checklist. For extended examples and templates, consult `core/skills/skill-development/references/skill-creator-full-guide.md`.

Follow the skill creation process (Steps 1–6) to generate SKILL.md files for the target skill directory.

## Key Requirements

- **Frontmatter:** Third-person description with specific trigger phrases
- **Body:** Imperative/infinitive voice, 1,500–2,000 words target
- **Progressive disclosure:** Move detailed content to `references/`
- **Validation:** Run the checklist from `skill-development` before finalizing

## Output Location

Target project's skills directory, typically:
- `core/skills/[skill-name]/SKILL.md` (core skills)
- `stacks/[stack]/skills/[skill-name]/SKILL.md` (stack-specific skills)
- `.claude/skills/[skill-name]/SKILL.md` (project-local skills)
