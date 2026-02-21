---
title: Add compaction trigger wiring
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.725425+01:00\\\"\""
closed-at: "2026-02-20T23:54:07.980052+01:00"
close-reason: completed
blocks:
  - pz-wire-end-to-a0cf1016
---

Context: PLAN.md:79, src/core/session/runtime_compact.zig; cause: compaction policy is disconnected from runtime loop; fix: trigger compaction on policy thresholds; deps: pz-wire-end-to-a0cf1016; verification: compaction trigger integration test passes.
