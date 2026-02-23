---
title: Stream replay and stats
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T11:29:37.542523+01:00\""
closed-at: "2026-02-23T11:37:25.618102+01:00"
close-reason: implemented and tested
---

Full context: src/core/session/reader.zig and src/app/runtime.zig sessionStats; cause: readToEndAlloc replay and redundant stats scans; fix: stream replay line-by-line and collapse stats to single-pass metadata usage with tests.
