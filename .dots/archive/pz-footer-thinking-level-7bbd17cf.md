---
title: Footer thinking level like pi
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T10:26:59.989865+01:00\""
closed-at: "2026-02-22T10:33:36.781378+01:00"
close-reason: "done: thinking label right-aligned with model as 'model · level', thinkingLabel returns @tagName, always shows level"
---

Pi shows 'model • thinking-level' in footer. pz only shows thinking label when non-adaptive and not in pi format. Fix: always show thinking level next to model like 'opus • medium'. File: panels.zig:223-227
