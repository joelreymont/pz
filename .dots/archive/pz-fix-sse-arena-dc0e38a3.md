---
title: Fix SSE arena per-frame leak
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T16:00:38.827111+01:00\""
closed-at: "2026-02-22T16:05:20.845187+01:00"
---

anthropic.zig:145,204,214,322 — SSE parser allocates per frame into long-lived arena, only frees at stream end. Parse per-frame in short-lived arena, copy only needed fields.
