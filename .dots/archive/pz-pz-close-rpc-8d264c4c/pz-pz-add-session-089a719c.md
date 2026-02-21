---
title: pz-add-session-stats-surface
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T20:07:00.037408+01:00\""
closed-at: "2026-02-21T20:12:00.996929+01:00"
close-reason: completed
---

Full context: src/app/runtime.zig /session and rpc session command; cause: session command surface lacks concrete session file/stats data; fix: include session path, bytes, and event line count in slash and rpc session outputs; proof: runtime tests assert stats fields.
