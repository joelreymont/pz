---
title: Add JSONL replay reader
status: closed
priority: 1
issue-type: task
created-at: "2026-02-20T21:25:57.625878+01:00"
closed-at: "2026-02-20T22:08:06+01:00"
close-reason: implemented strict JSONL replay reader with deterministic errors
blocks:
  - pizi-add-jsonl-append-2b2937fd
---

Context: PLAN.md:36-37, src/core/session/reader.zig; cause: stored sessions cannot be replayed; fix: implement reader with strict decode errors; deps: pizi-add-jsonl-append-2b2937fd; verification: replay reproduces event stream exactly.
