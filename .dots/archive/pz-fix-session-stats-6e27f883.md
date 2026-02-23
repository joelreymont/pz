---
title: Fix session stats error policy
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T11:58:25.787600+01:00\""
closed-at: "2026-02-23T12:12:32.147908+01:00"
close-reason: completed
---

Full context: src/app/runtime.zig sessionStats uses catch break while replaying, silently masking malformed replay; fix: surface parse/replay errors explicitly in stats output path with deterministic behavior and tests.
