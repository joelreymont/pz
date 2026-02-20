---
title: Add session persistence regression tests
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.638053+01:00\\\"\""
closed-at: "2026-02-20T23:33:15.656573+01:00"
close-reason: completed
blocks:
  - pizi-add-compaction-checkpoint-3719b422
---

Context: PLAN.md:34-39, test/session_*; cause: persistence logic is unguarded; fix: add writer-reader-compaction-retry regression suite; deps: pizi-add-compaction-checkpoint-3719b422,pizi-add-retry-metadata-135719e9; verification: targeted session test suite is green.
