---
title: Add model and provider command flags
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T19:08:12.567974+01:00\""
closed-at: "2026-02-21T19:08:16.159768+01:00"
close-reason: completed
---

Full context: src/app/args.zig:1 src/app/config.zig:1 src/app/cli.zig:1; cause: missing model/provider CLI override surface; fix: parse --model and --provider-cmd and apply highest-precedence config override; deps: parent.
