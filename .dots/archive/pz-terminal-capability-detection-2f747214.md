---
title: Terminal capability detection
status: closed
priority: 3
issue-type: task
created-at: "\"2026-02-21T22:46:40.571525+01:00\""
closed-at: "2026-02-21T23:25:05.553362+01:00"
close-reason: done
---

Check COLORTERM env var for truecolor support. Fall back to 256-color (idx) if no truecolor. Map theme rgb values to closest 256-color palette entries. Files: render.zig (conditional SGR emission), theme.zig (add idx fallbacks)
