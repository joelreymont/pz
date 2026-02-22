---
title: Editor border color per thinking level
status: open
priority: 2
issue-type: task
created-at: "2026-02-22T10:26:59.987053+01:00"
---

Pi changes editor border color based on thinking level (thinking_off/min/low/med/high/xhigh colors). pz uses fixed thinking_high for border. Fix: pass thinking level to Ui, select border color from theme. Files: harness.zig:167-168, theme.zig thinking_* colors
