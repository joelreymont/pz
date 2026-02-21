---
title: Add compaction checkpoint state
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.629423+01:00\\\"\""
closed-at: "2026-02-20T23:33:08.254916+01:00"
close-reason: completed
blocks:
  - pz-add-jsonl-replay-c17dc176
---

Context: PLAN.md:38, src/core/session/compact.zig; cause: session files grow without control; fix: add compaction checkpoint metadata and rewrite path; deps: pz-add-jsonl-replay-c17dc176; verification: compaction keeps semantic event equivalence.
