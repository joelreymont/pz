---
title: Add read and write tool handlers
status: closed
priority: 1
issue-type: task
created-at: "2026-02-20T21:25:57.644704+01:00"
closed-at: "2026-02-20T22:08:06+01:00"
close-reason: added read and write handlers with typed errors and tests
blocks:
  - pizi-add-tool-registry-b7b42bcf
---

Context: PLAN.md:42, src/core/tools/read.zig src/core/tools/write.zig; cause: core file tools missing; fix: implement read/write handlers with explicit error unions; deps: pizi-add-tool-registry-b7b42bcf; verification: read/write tool tests pass.
