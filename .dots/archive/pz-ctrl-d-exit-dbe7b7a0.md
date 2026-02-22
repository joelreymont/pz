---
title: Ctrl-D exit + thinking level cycling
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-02-22T09:43:18.825953+01:00\\\"\""
closed-at: "2026-02-22T09:59:48.746345+01:00"
close-reason: Ctrl-D exits on empty, shift-tab cycles thinking off→min→low→med→high→xhigh→adaptive, footer shows thinking label
---

Ctrl-D should exit when editor empty (like pi). Shift+Tab cycles thinking: off->minimal->low->medium->high->xhigh->off. Need: add ctrl_d to Key enum in editor.zig, handle in input.zig (0x04 byte), add shift_tab key, wire thinking level state in runtime.zig, display in footer. Ref: pi keybindings.ts
