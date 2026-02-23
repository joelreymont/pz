---
title: "Find tool: truncate instead of TooLarge error"
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T09:21:36.307792+01:00\""
closed-at: "2026-02-23T09:26:04.413597+01:00"
---

find.zig:58-63 returns hard error at hit threshold. Match grep behavior: break and return truncated results with metadata.
