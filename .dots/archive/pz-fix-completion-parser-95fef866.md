---
title: Fix completion/parser/find behavior
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T11:29:37.549733+01:00\""
closed-at: "2026-02-23T11:37:25.624251+01:00"
close-reason: implemented and tested
---

Full context: src/modes/tui/harness.zig pathcomp hot path, src/modes/tui/transcript.zig ANSI parser OSC handling, src/core/tools/find.zig TooLarge policy; cause: per-keystroke scans, OSC payload leakage, inconsistent truncation behavior; fix: add cache, parse OSC, truncate deterministically with tests.
