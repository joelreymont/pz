---
title: Extend tool schema for grep/find/ls
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T18:52:43.213687+01:00\""
closed-at: "2026-02-21T18:57:38.827301+01:00"
close-reason: completed
---

Full context: src/core/tools/mod.zig:1 src/core/loop.zig:640; cause: kind/args union omits grep/find/ls so provider calls cannot be represented; fix: add kinds, args, parser paths, and contract tests; deps: parent.
