---
title: pizi-add-pi-config-tests
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-02-21T21:01:57.460661+01:00\\\"\""
closed-at: "2026-02-21T21:02:59.395042+01:00"
close-reason: completed
---

Full context: src/app/config.zig:180, add deterministic tests for pi settings load and precedence using tmp home path; cause: host settings must not leak into tests; fix: env.home-controlled load.
