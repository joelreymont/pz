---
title: Implement grep/find/ls handlers
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T18:52:43.217782+01:00\""
closed-at: "2026-02-21T18:57:38.832151+01:00"
close-reason: completed
---

Full context: src/core/tools/grep.zig src/core/tools/find.zig src/core/tools/ls.zig; cause: no executable handlers for search/list tool calls; fix: add deterministic handlers with truncation/error envelopes and tests; deps: Extend tool schema for grep/find/ls.
