---
title: Add retry metadata persistence
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.635006+01:00\\\"\""
closed-at: "2026-02-20T23:33:08.260190+01:00"
close-reason: completed
blocks:
  - pizi-add-jsonl-replay-c17dc176
---

Context: PLAN.md:38, src/core/session/retry_state.zig; cause: retry context is lost across restarts; fix: persist retry counters/backoff state with session; deps: pizi-add-jsonl-replay-c17dc176; verification: retry state restores after reload tests.
