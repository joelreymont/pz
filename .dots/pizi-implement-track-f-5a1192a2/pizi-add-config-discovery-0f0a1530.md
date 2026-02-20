---
title: Add config discovery pipeline
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.707575+01:00\\\"\""
closed-at: "2026-02-20T23:37:42.233358+01:00"
close-reason: completed
blocks:
  - pizi-add-cli-arg-f7fa2220
---

Context: PLAN.md:73, src/app/config.zig; cause: config source precedence is undefined; fix: implement file/env/flag merge with explicit priority; deps: pizi-add-cli-arg-f7fa2220; verification: config precedence tests pass.
