---
title: Add json and rpc mode wiring
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T19:08:12.564460+01:00\""
closed-at: "2026-02-21T19:08:16.156411+01:00"
close-reason: completed
---

Full context: src/app/args.zig:1 src/app/config.zig:1 src/app/cli.zig:1 src/app/runtime.zig:245; cause: pizi had only tui/print; fix: add mode enum parsing/config/runtime switch and rpc/json executors; deps: parent.
