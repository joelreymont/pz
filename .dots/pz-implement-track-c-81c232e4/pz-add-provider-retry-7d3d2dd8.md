---
title: Add provider retry and backoff policy
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.669061+01:00\\\"\""
closed-at: "2026-02-20T23:40:13.510830+01:00"
close-reason: completed
blocks:
  - pz-add-provider-adapter-07ed29f9
---

Context: PLAN.md:50, src/core/providers/retry.zig; cause: transient provider failures are not recoverable; fix: implement typed retry policy with bounded backoff; deps: pz-add-provider-adapter-07ed29f9; verification: retry policy tests pass.
