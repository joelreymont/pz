---
title: Implement pi streaming input parity
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T21:18:45.579134+01:00\""
closed-at: "2026-02-23T21:31:24.127154+01:00"
close-reason: implemented live steering/follow-up queue with non-blocking TUI input, alt-up restore, dual notify reader, and tests
---

Full context: runtime blocks input during tctx.run so steering while running is impossible. Need Enter=>steer while streaming, Alt+Enter=>follow-up queue, Alt+Up restore queued into editor like pi. Files: src/app/runtime.zig, src/modes/tui/editor.zig, src/modes/tui/panels.zig. Add integration tests that prove behavior during active stream.
