---
title: Add streaming parser to events
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.665613+01:00\\\"\""
closed-at: "2026-02-20T23:40:27.792873+01:00"
close-reason: completed
blocks:
  - pz-add-first-provider-801251c6
---

Context: PLAN.md:50, src/core/providers/stream_parse.zig; cause: stream chunks are not normalized to internal events; fix: parse chunks into schema events with ordering guarantees; deps: pz-add-first-provider-801251c6; verification: stream parser tests pass.
