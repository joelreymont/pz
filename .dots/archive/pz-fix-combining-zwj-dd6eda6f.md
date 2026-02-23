---
title: Fix combining/ZWJ zero-width in wcwidth
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T09:21:27.753160+01:00\""
closed-at: "2026-02-23T09:24:00.730744+01:00"
---

wcwidth.zig:5 returns 1 for combining marks/ZWJ. Fix: add zero-width ranges for combining marks (U+0300-U+036F etc), ZWJ (U+200D), variation selectors (U+FE00-U+FE0F). Add tests. Affects: frame.zig:127, transcript.zig:549, harness.zig:494, vscreen.zig:154
