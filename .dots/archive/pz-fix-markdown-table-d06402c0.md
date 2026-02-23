---
title: Fix markdown table drawing
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T20:15:15.869403+01:00\""
closed-at: "2026-02-23T20:15:18.936036+01:00"
close-reason: completed
---

Full context: src/modes/tui/transcript.zig table rendering rebuilt per-row and separator alignment was inconsistent for mixed-width rows; implemented block layout with consistent column widths and added regression tests in src/modes/tui/transcript.zig and src/modes/tui/fixture.zig.
