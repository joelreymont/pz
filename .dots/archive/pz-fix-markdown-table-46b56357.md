---
title: Fix markdown table render
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T19:36:42.011180+01:00\""
closed-at: "2026-02-23T19:38:44.143322+01:00"
---

Full context: src/modes/tui/transcript.zig draw path wraps markdown rows with generic wrapIter causing table rows to split and render incorrectly; add markdown-aware iterator/count path preserving table rows, keep regular wrapping, and strengthen tests for table rows and skipped-line markdown state.
