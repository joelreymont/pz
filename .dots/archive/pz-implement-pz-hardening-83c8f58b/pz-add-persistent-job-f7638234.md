---
title: Add persistent job journal + recovery
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-23T13:20:43.269456+01:00\\\"\""
closed-at: "2026-02-23T13:34:30.474942+01:00"
close-reason: completed
blocks:
  - pz-implement-bg-supervisor-3f7027ee
---

File: /Users/joel/Work/pizi/src/app/job_journal.zig:1; cause: crash leaves unknown bg job ownership; fix: append-only journal with replay, stale cleanup, and compaction; why: deterministic recovery and safe orphan cleanup.
