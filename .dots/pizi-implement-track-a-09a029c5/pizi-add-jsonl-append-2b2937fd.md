---
title: Add JSONL append writer
status: closed
priority: 1
issue-type: task
created-at: "2026-02-20T21:25:57.622515+01:00"
closed-at: "2026-02-20T22:08:06+01:00"
close-reason: implemented append-only JSONL writer with flush policy
blocks:
  - pizi-add-session-event-3e18343e
---

Context: PLAN.md:36, src/core/session/writer.zig; cause: sessions cannot be persisted incrementally; fix: implement append-only JSONL writer with flush policy; deps: pizi-add-session-event-3e18343e; verification: append preserves event order in tests.
