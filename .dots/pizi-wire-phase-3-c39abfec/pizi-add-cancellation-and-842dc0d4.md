---
title: Add cancellation and retry control flow
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.721910+01:00\\\"\""
closed-at: "2026-02-20T23:54:07.974387+01:00"
close-reason: completed
blocks:
  - pizi-wire-end-to-a0cf1016
---

Context: PLAN.md:79, src/core/control.zig; cause: cancel/retry behavior is missing; fix: add cancellation tokens and retry orchestration; deps: pizi-wire-end-to-a0cf1016; verification: cancel/retry integration tests pass.
