---
title: Default model resolves to literal string
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T22:10:34.584913+01:00\""
closed-at: "2026-02-22T22:13:24.328161+01:00"
---

When --model not specified, model='default' is sent to API causing 404. Need to resolve 'default' to actual model ID (e.g. claude-sonnet-4-5). File: src/app/runtime.zig, src/app/config.zig:4
