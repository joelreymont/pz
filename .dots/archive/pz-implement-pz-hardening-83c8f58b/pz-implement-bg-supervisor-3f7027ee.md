---
title: Implement bg supervisor + wait backend
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-23T13:20:43.265911+01:00\""
closed-at: "2026-02-23T13:45:37.076162+01:00"
close-reason: completed
---

File: /Users/joel/Work/pizi/src/app/bg_supervisor.zig:1; cause: process tracking/exit handling scattered; fix: central supervisor using kqueue NOTE_EXIT (macOS) and pidfd/epoll (Linux) without polling; why: robust async lifecycle.
