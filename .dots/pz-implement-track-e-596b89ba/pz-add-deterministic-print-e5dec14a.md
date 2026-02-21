---
title: Add deterministic print formatter
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.696973+01:00\\\"\""
closed-at: "2026-02-20T23:51:02.052966+01:00"
close-reason: completed
blocks:
  - pz-add-print-mode-1bb5c02a
---

Context: PLAN.md:68, src/modes/print/format.zig; cause: stdout format stability is unspecified; fix: implement deterministic formatter with fixed ordering; deps: pz-add-print-mode-1bb5c02a; verification: formatter golden tests pass.
