---
title: Fix upgrade bad-header failures
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T19:51:55.152331+01:00\""
closed-at: "2026-02-23T19:52:37.832418+01:00"
---

Full context: upgrade HTTP requests can hit 400 invalid header name in some proxy/corp paths while wget succeeds; implement canonical header names and fallback retry modes (wget-like and bare) when transport/header parse or 400 invalid-header responses occur; add unit tests for bad-header body detection.
