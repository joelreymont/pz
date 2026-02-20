---
title: Add tool output truncation policy
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.651457+01:00\\\"\""
closed-at: "2026-02-20T23:28:11.582338+01:00"
close-reason: completed
blocks:
  - pizi-add-read-and-b68291bf
---

Context: PLAN.md:43, src/core/tools/output.zig; cause: unbounded tool output can break UI/session; fix: implement truncation metadata and byte limits; deps: pizi-add-read-and-b68291bf,pizi-add-bash-and-238954e0; verification: truncation tests assert stable boundaries.
