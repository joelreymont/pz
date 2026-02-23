---
title: Refactor runtime to labeled switch FSM
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-23T13:20:43.258379+01:00\""
closed-at: "2026-02-23T13:43:52.775750+01:00"
close-reason: completed
---

File: /Users/joel/Work/pizi/src/app/runtime.zig:1; cause: implicit control flow across handlers; fix: explicit Zig labeled while+switch state machine with transition guards; why: correctness and testability of lifecycle transitions.
