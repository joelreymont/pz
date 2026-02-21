---
title: Add tool lifecycle event wiring
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.654913+01:00\\\"\""
closed-at: "2026-02-20T23:28:16.621023+01:00"
close-reason: completed
blocks:
  - pz-add-tool-output-08fa0c33
---

Context: PLAN.md:44, src/core/tools/runtime.zig; cause: call/result lifecycle not emitted consistently; fix: emit start/output/end events tied to schema; deps: pz-add-tool-output-08fa0c33; verification: lifecycle sequence tests pass.
