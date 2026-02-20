---
title: pizi-close-remaining-surface
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T19:43:02.563641+01:00\""
closed-at: "2026-02-21T19:46:22.469226+01:00"
close-reason: completed
---

Full context: src/app/runtime.zig, src/modes/tui/panels.zig, src/modes/tui/harness.zig; cause: interactive/runtime surface still misses tool command control and provider visibility in TUI status; fix: implement all remaining commands and status wiring with tests; proof: targeted runtime/tui tests and full suite green.
