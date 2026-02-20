---
title: Wire end-to-end agent loop
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.718454+01:00\\\"\""
closed-at: "2026-02-20T23:41:18.491615+01:00"
close-reason: completed
blocks:
  - pizi-add-session-persistence-71bc89cc
---

Context: PLAN.md:78, src/core/loop.zig; cause: tracks run in isolation; fix: compose session, provider, tools, and modes in one loop; deps: pizi-add-session-persistence-71bc89cc,pizi-add-tool-lifecycle-b07314d3,pizi-add-provider-streaming-18041bbc,pizi-add-mode-dispatch-3ae8b527; verification: end-to-end loop smoke test passes.
