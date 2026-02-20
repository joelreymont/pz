---
title: Wire builtins and cli tool masks
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T18:52:43.220964+01:00\""
closed-at: "2026-02-21T18:57:38.835501+01:00"
close-reason: completed
---

Full context: src/core/tools/builtin.zig src/app/args.zig src/app/cli.zig; cause: registry/mask parser currently knows only read/write/bash/edit; fix: include grep/find/ls in canonical order, update mask parsing/help, and add tests; deps: Implement grep/find/ls handlers.
