---
title: Fix unicode width parity
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T11:29:37.529613+01:00\""
closed-at: "2026-02-23T11:37:25.607591+01:00"
close-reason: implemented and tested
---

Full context: src/modes/tui/wcwidth.zig and callers frame.zig,harness.zig,transcript.zig,vscreen.zig; cause: zero-width classes (combining/ZWJ/VS) treated as width 1; fix: add zero-width handling and regression tests for combining+emoji sequences to prevent render/cursor drift.
