---
title: Add unified runtime error reporting
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.728987+01:00\\\"\""
closed-at: "2026-02-20T23:54:19.000693+01:00"
close-reason: completed
blocks:
  - pizi-add-cancellation-and-842dc0d4
---

Context: PLAN.md:80, src/core/errors.zig; cause: errors are emitted inconsistently across subsystems; fix: centralize error reporting format and propagation; deps: pizi-add-cancellation-and-842dc0d4,pizi-add-compaction-trigger-f73fc4db; verification: runtime error golden tests pass.
