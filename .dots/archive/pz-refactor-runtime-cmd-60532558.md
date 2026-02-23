---
title: Refactor runtime command core
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T11:58:25.784025+01:00\""
closed-at: "2026-02-23T12:12:32.143270+01:00"
close-reason: completed
---

Full context: src/app/runtime.zig has duplicated RPC/slash routing and duplicated slash invocation paths at startup/interactive/piped; cause: command parsing/execution spread across large switches; fix: introduce shared slash command runner + shared dispatch helpers and tighten error handling.
