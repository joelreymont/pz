---
title: Improve upgrade HTTP error detail
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T19:13:52.150906+01:00\""
closed-at: "2026-02-23T19:15:19.813701+01:00"
close-reason: added proxy env support + html error extraction for upgrade HTTP failures with tests
---

Full context: src/app/update.zig currently prints truncated HTML snippet on HTTP 4xx/5xx. Parse and surface meaningful HTML message (title/h2/p) when present; fallback to sanitized snippet. Keep status code primary. Add regression tests.
