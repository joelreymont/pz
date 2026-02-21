---
title: Implement track-A session persistence
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.570368+01:00\\\"\""
closed-at: "2026-02-20T23:33:15.662011+01:00"
close-reason: completed
blocks:
  - pz-define-core-contracts-63ce9129
---

Context: PLAN.md:34-39; cause: session persistence pipeline is not implemented; fix: add JSONL writer/reader, compaction, retry state; deps: pz-define-core-contracts-63ce9129; verification: persistence tests pass for write/read/retry flows.
