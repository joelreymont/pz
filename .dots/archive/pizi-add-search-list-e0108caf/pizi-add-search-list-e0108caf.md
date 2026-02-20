---
title: Add search/list built-in tools parity
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T18:52:36.462476+01:00\""
closed-at: "2026-02-21T18:57:38.841495+01:00"
close-reason: completed
---

Full context: src/core/tools/mod.zig:1 src/core/tools/builtin.zig:1 src/core/loop.zig:520; cause: pizi lacks pi built-ins grep/find/ls, blocking user-visible tool parity; fix: extend tool kind/args schema, implement handlers, wire builtin registry/tool masks, and verify with tests; deps: none.
