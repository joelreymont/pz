---
title: Eliminate double wrap-count pass in transcript
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T09:21:29.858700+01:00\""
closed-at: "2026-02-23T09:25:00.530793+01:00"
---

transcript.zig:196-219 does two full passes when scrollbar present. Fix: single pass at text_w (scrollbar width), or cache line counts. Hot path optimization.
