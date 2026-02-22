---
title: Model cycling (Ctrl-P)
status: closed
priority: 3
issue-type: task
created-at: "\"\\\"2026-02-22T09:43:27.434862+01:00\\\"\""
closed-at: "2026-02-22T10:07:13.581985+01:00"
close-reason: Ctrl-P cycles opus→sonnet→haiku, updates footer and ctx_limit
---

Pi cycles through scoped models with Ctrl-P/Shift-Ctrl-P, opens selector with Ctrl-L. Need: --models CLI flag for patterns, model registry with scoped list, ctrl_p/shift_ctrl_p keys in input.zig, cycle logic in runtime.zig, update footer on change. Ref: pi model-registry.ts, keybindings.ts
