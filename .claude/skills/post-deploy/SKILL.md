---
description: "Post-deploy production smoke test (door for the smoke-tester agent). Run after a deploy to catch schema drift, RLS failures, and backend errors hidden behind 200s. Triggers: '/post-deploy', 'smoke test the deploy', 'post-deploy check', 'is the deploy healthy'."
---

# /post-deploy — production smoke test

The entry point for the `smoke-tester` agent. Run it right after a deploy (or any time you want to
confirm the live site is healthy) to catch the class of bugs the pre-merge quality gates structurally
cannot see: a 200 response with an error payload in the body, schema drift, a broken RLS policy, a
missing column. The agent visits public pages as an anonymous visitor, intercepts every API response,
and returns a pass/fail report. **Read-only** — it diagnoses, never fixes or deploys.

## Usage

- `/post-deploy` — smoke-test the default base URL (discovered from project config).
- `/post-deploy --base=https://app.example.com` — smoke-test a specific URL (e.g. a preview deploy).

## Process

1. **Dispatch `@smoke-tester`**, passing through any `--base=URL` argument. The agent discovers the
   Playwright config, base URL, and API domains dynamically (it is stack-agnostic).
2. **Write its report** to the run folder if one is active, else surface it inline. For an ad-hoc run,
   the canonical output path is
   `docs/step-5-pipeline/YYYY-MM-DD/HHmm-AUDIT-post-deploy/findings/smoke-tester.md`.
3. **Surface the verdict.** PASS → report clean. FAIL → list each failing page/endpoint with its
   status + error body, and recommend the follow-up (a `/nimble` fix run, or `git revert` of the
   deploy if the failure is severe). Do NOT auto-fix — `/post-deploy` is a read-only health check.

## Scope

- Read-only. The skill orchestrates `smoke-tester` and reports; it never edits, deploys, or reverts.
- Pairs with `/batch-gate` (the canonical gate-sequencer; the former `release-manager` agent was retired
  into it — ADR-081) — `/batch-gate` validates *before* shipping; `/post-deploy` validates *after*.
- For pre-merge quality gates use `/batch-gate`; for catching semantic merge conflicts use
  `/post-merge-gate`. `/post-deploy` is specifically the *live deployed site* check.
