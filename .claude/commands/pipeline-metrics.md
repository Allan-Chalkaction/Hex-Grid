---
description: Analyze pipeline throughput and bottlenecks from the metrics log
---

Read `docs/step-3-specs/_metrics.jsonl` (an append-only JSONL file where each line is a JSON object with `slug`, `status`, and `timestamp` fields).

Analyze the data and report:

1. **Pipeline throughput:** Features completed (reached DONE status) per week
2. **Stage durations:** Average time at each status (READY_FOR_ARCH → READY_FOR_BUILD → DONE)
3. **Current blockers:** Features at BLOCKED or NEEDS_FIX and how long they've been there
4. **Stale entries:** Features with no status change in 7+ days
5. **Revision rate:** How often features go through NEEDS_SPEC_REVISION or NEEDS_FIX cycles
6. **Bottleneck identification:** Which pipeline stage takes longest on average

Format as a clear report with the most actionable information first.

If the metrics file doesn't exist or is empty, explain that pipeline metrics tracking is automatic (via the `suggested-next-step.sh` hook) and will populate as features flow through the pipeline.
