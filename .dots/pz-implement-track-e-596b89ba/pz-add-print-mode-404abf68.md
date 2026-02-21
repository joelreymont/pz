---
title: Add print mode exit/error mapping
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.700422+01:00\\\"\""
closed-at: "2026-02-20T23:51:10.425410+01:00"
close-reason: completed
blocks:
  - pz-add-deterministic-print-e5dec14a
---

Context: PLAN.md:67-68, src/modes/print/errors.zig; cause: failure semantics are inconsistent; fix: map typed errors to stable exit codes/messages; deps: pz-add-deterministic-print-e5dec14a; verification: exit-code mapping tests pass.
