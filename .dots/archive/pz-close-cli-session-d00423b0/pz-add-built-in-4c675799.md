---
title: Add built-in tool selection flags
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T18:43:05.360844+01:00\""
closed-at: "2026-02-21T18:52:24.080112+01:00"
close-reason: completed
---

Full context: src/app/args.zig:1 src/app/runtime.zig:1 src/core/tools/builtin.zig:1; cause: tool set is fixed, no --tools/--no-tools control; fix: parse flags, validate names, filter registry deterministically, add tests; deps: parent.
