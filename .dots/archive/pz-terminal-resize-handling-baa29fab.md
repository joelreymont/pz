---
title: Terminal resize handling
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T22:04:00.235617+01:00\""
closed-at: "2026-02-21T22:31:17.672679+01:00"
close-reason: "done: Ui.resize with noop optimization"
blocks:
  - pz-upgrade-color-to-db62d5f8
---

Step 7: SIGWINCH handler. Realloc frame+renderer on resize. Clamp min 1x1. harness.zig, render.zig
