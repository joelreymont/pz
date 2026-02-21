---
title: Wire executable runtime path
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-21T09:30:49.609258+01:00\\\"\""
closed-at: "2026-02-21T09:36:55.512800+01:00"
close-reason: completed
---

Context: src/app/mod.zig run command is a no-op; cause: no dispatch to mode/provider/store; fix: implement concrete runtime wiring for provider/session/tools and execute run modes with tests.
