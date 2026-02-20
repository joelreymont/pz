---
title: Wire session strategy in runtime
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T18:43:05.357945+01:00\""
closed-at: "2026-02-21T18:52:24.076932+01:00"
close-reason: completed
---

Full context: src/app/runtime.zig:1 src/core/session/path.zig:1; cause: runtime always creates new sid and persists unconditionally; fix: support explicit sid/path, continue-most-recent selection, and ephemeral no-session behavior with deterministic errors/tests; deps: Add session control flags.
