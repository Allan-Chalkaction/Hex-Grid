# /idea-ingest — segmentation prompt + output contract

<!-- Support doc for /idea-ingest. (Briefly lived under core/skills/bulk-jam/ when ADR-081 merged idea-ingest
     into /bulk-jam --ingest; ADR-112 split capture back out to the standalone /idea-ingest door.) -->


The single LLM pass that turns a transcript / pasted discussion / session-log into a list of candidate ideas.
One pass per invocation (chunked for inputs over ~10,000 characters). This is segmentation, **not**
architecture — surface distinct sparks, do not design them.

## Prompt (use verbatim, fill `{{INPUT}}`)

> You are segmenting a discussion into **distinct, separable proactive ideas** — things someone said they'd
> want to build, try, or explore eventually. Read the text below and extract each genuinely-distinct idea.
>
> Rules:
> - One object per **distinct** idea. Merge restatements of the same idea; split a sentence that contains two.
> - Do **not** invent ideas that aren't in the text. Do **not** design or expand — capture the spark only.
> - Skip pure status/discussion that isn't a proactive "I want to build/try X" spark.
> - `short_slug`: a kebab-case identifier, ~6 words max, lowercased, non-alphanumerics → `-`, collapsed,
>   trimmed (the same rule `/idea` uses for its filename slug).
> - `one_line_summary`: one line describing the idea, in the speaker's framing.
> - `evidence_excerpt`: a **verbatim** quote of the source span the idea came from (so the operator can
>   verify at the review gate).
>
> Output a **JSON array** of objects with exactly the fields `short_slug`, `one_line_summary`,
> `evidence_excerpt` — and nothing else (no prose, no markdown fences around it). It must parse as JSON.
>
> TEXT:
> {{INPUT}}

## Output contract

```json
[
  {
    "short_slug": "transcript-ingest-skill",
    "one_line_summary": "A skill that turns a transcript into N backlog idea files.",
    "evidence_excerpt": "ideas surface in discussion, not at a /idea prompt — I typed ~15 one by one"
  }
]
```

- Exactly three fields per object: `short_slug`, `one_line_summary`, `evidence_excerpt`.
- Parseable as JSON with no LLM re-pass.
- Empty array `[]` is valid (nothing to capture) — the review gate then reports "no candidates".

## Fallbacks (mirror the SKILL contract)

- **Too short** (well under one idea's worth of text) → degenerate to a single forwarded `/idea` invocation
  with an operator note, still gated by review.
- **Too long** (> ~10,000 characters) → chunk and run the pass per chunk, then merge candidates; when chunking
  is ambiguous, **truncate-with-warning** (process the first ~10k chars and surface that the tail was not
  segmented).
