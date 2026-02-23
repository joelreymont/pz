---
title: Fix /up arrows and utf8 crash
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T19:02:54.627391+01:00\""
closed-at: "2026-02-23T19:04:36.220620+01:00"
close-reason: fixed SS3 arrows, UTF-8 safe slash output, and added regressions
---

Full context: src/modes/tui/input.zig parseSS3 misses A/B causing arrow navigation failure in app-cursor mode; src/app/runtime.zig slash cmd output can carry non-UTF-8 and crash transcript. Fix SS3 mapping + add UTF-8-safe info insertion and regression tests.
