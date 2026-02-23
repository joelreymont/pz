---
title: Fix read TooLarge behavior
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T19:56:36.195247+01:00\""
closed-at: "2026-02-23T20:05:03.619758+01:00"
close-reason: completed
---

Full context: read tool returns tool-failed:TooLarge for large files; implement truncating/streaming read behavior so read can return partial content with metadata instead of hard failure where possible.
