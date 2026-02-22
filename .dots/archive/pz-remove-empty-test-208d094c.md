---
title: Remove empty test modules
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T16:00:42.872605+01:00\""
closed-at: "2026-02-22T16:02:15.183148+01:00"
---

all_tests.zig:14, app_runtime_tests.zig:3 — Tests only import modules and assert nothing. Inflated passing signal. Replace with real assertions or remove.
