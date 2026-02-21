---
title: Add process-backed provider transport
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-21T09:30:55.723626+01:00\\\"\""
closed-at: "2026-02-21T09:36:55.491067+01:00"
close-reason: completed
---

Context: first_provider lacks production transport; fix: add child-process raw transport that writes request JSON to stdin and streams line chunks from stdout; add tests.
