---
name: Skill Development
description: Use when the user wants to "create a skill", "add a new skill", "write a skill", "improve skill description", "organize skill content", "audit skill quality", or needs guidance on skill structure or development best practices.
---

# Skill Development

This skill provides the canonical reference for creating and maintaining effective skills. Skills are modular, self-contained packages that extend Claude's capabilities through specialized knowledge, workflows, and tools.

## Anatomy of a Skill

```
skill-name/
├── SKILL.md (required)
│   ├── YAML frontmatter (name + description required)
│   └── Markdown instructions
└── Bundled Resources (optional)
    ├── scripts/          - Executable code (Python/Bash/etc.)
    ├── references/       - Documentation loaded into context as needed
    └── assets/           - Files used in output (templates, icons, fonts)
```

### Progressive Disclosure (3-Tier Loading)

1. **Metadata (name + description)** — Always in context (~100 words)
2. **SKILL.md body** — When skill triggers (<5k words, target 1,500–2,000)
3. **Bundled resources** — As needed (unlimited; scripts can execute without reading into context)

## Skill Creation Process

### Step 1: Understand Usage with Concrete Examples

Identify concrete examples of how the skill will be used. Ask:
- What functionality should the skill support?
- What would a user say that should trigger this skill?
- What are the common and edge-case workflows?

### Step 2: Plan Reusable Contents

Analyze each example to identify what reusable resources to include:

| Resource Type | When to Include | Example |
|---------------|-----------------|---------|
| `scripts/` | Same code rewritten repeatedly or deterministic reliability needed | `scripts/validate-hook-schema.sh` |
| `references/` | Documentation Claude should reference while working (schemas, API docs, policies) | `references/patterns.md` |
| `assets/` | Files used in output, not loaded into context | `assets/template/` |

### Step 3: Create Structure

```bash
mkdir -p skills/skill-name/{references,examples,scripts}
touch skills/skill-name/SKILL.md
```

Create only the directories actually needed. Delete any unused directories.

### Step 4: Write the Skill

Remember: the skill is written **for another Claude instance to use**. Focus on procedural knowledge, domain-specific details, and reusable assets that are non-obvious.

#### Frontmatter Description

Use third-person format with specific trigger phrases:

```yaml
description: This skill should be used when the user asks to "specific phrase 1", "specific phrase 2", "specific phrase 3".
```

**Good:** `This skill should be used when the user asks to "create a hook", "add a PreToolUse hook", "validate tool use", or mentions hook events.`
**Bad:** `Use this skill when working with hooks.` (wrong person, vague, no trigger phrases)

#### Body Content

- Write in **imperative/infinitive form** (verb-first), not second person
- Target **1,500–2,000 words** (max 5,000)
- Move detailed content to `references/`
- Reference all bundled resources explicitly so Claude knows they exist

**Correct:** `Parse the frontmatter using sed. Validate values before use.`
**Incorrect:** `You should parse the frontmatter. You need to validate values.`

#### Resource References

Always point to bundled resources in SKILL.md:

```markdown
## Additional Resources
- **`references/patterns.md`** — Common patterns and detailed techniques
- **`references/advanced.md`** — Advanced use cases and edge cases
- **`examples/working-example.sh`** — Complete runnable example
```

### Step 5: Validate

Run through the validation checklist:

**Structure:**
- [ ] SKILL.md exists with valid YAML frontmatter (name + description)
- [ ] Markdown body is present and substantial
- [ ] All referenced files exist

**Description Quality:**
- [ ] Third person ("This skill should be used when...")
- [ ] Specific trigger phrases users would say
- [ ] Concrete scenarios listed

**Content Quality:**
- [ ] Imperative/infinitive form throughout (no "you")
- [ ] Body is lean (1,500–2,000 words ideal, <5k max)
- [ ] Detailed content in `references/`, not SKILL.md
- [ ] All bundled resources referenced in body

**Progressive Disclosure:**
- [ ] Core concepts and essential procedures in SKILL.md
- [ ] Detailed docs in `references/`
- [ ] Working code in `examples/`
- [ ] Utilities in `scripts/`

### Step 6: Iterate

After using the skill on real tasks:
1. Notice struggles or inefficiencies
2. Strengthen trigger phrases in description
3. Move long sections from SKILL.md to `references/`
4. Add missing examples or scripts
5. Clarify ambiguous instructions

## Common Mistakes

### Weak Trigger Description
**Bad:** `Provides guidance for working with hooks.`
**Good:** `This skill should be used when the user asks to "create a hook", "add a PreToolUse hook", "validate tool use", or mentions hook events.`

### Too Much in SKILL.md
**Bad:** 8,000 words in one file, everything inline.
**Good:** 1,800 words in SKILL.md + `references/patterns.md` (2,500 words) + `references/advanced.md` (3,700 words).

### Second-Person Writing
**Bad:** `You should start by reading the configuration file.`
**Good:** `Start by reading the configuration file.`

### Missing Resource References
If `references/` or `examples/` exist but SKILL.md doesn't mention them, Claude won't know to load them.

## Progressive Disclosure Guidelines

### What belongs in SKILL.md
- Core concepts and overview
- Essential procedures and workflows
- Quick reference tables
- Pointers to references/examples/scripts
- Most common use cases

### What belongs in references/
- Detailed patterns and advanced techniques
- Comprehensive API documentation
- Migration guides
- Edge cases and troubleshooting
- Extensive examples and walkthroughs

### Size guidance
- SKILL.md: 1,500–2,000 words (max 5,000)
- Each reference file: 2,000–5,000+ words
- Large references (>10k words): include grep search patterns in SKILL.md

## Additional Resources

- **`references/skill-creator-full-guide.md`** — Complete Anthropic skill-creator methodology with extended examples, plugin-specific considerations, and implementation workflow details
