---
title: Decouple TUI test oracle width
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T11:58:25.790854+01:00\""
closed-at: "2026-02-23T12:12:32.151635+01:00"
close-reason: completed
---

Full context: src/modes/tui/vscreen.zig uses production wcwidth; cause: test oracle coupling; fix: independent width model option in VScreen tests (or direct frame assertions) to catch width regressions.
