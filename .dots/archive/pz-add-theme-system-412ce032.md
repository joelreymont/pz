---
title: Add theme system
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-02-21T22:03:52.392158+01:00\\\"\""
closed-at: "2026-02-21T22:08:19.090103+01:00"
close-reason: done
blocks:
  - pz-upgrade-color-to-db62d5f8
---

Step 2: Create theme.zig with pi dark.json colors as comptime constants. Replace all hardcoded colors in panels.zig, transcript.zig, harness.zig with theme refs. src/modes/tui/theme.zig
