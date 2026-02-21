---
title: pz-close-rpc-session-surface-gaps
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T20:07:00.027001+01:00\""
closed-at: "2026-02-21T20:12:01.002827+01:00"
close-reason: completed
---

Full context: src/app/runtime.zig, src/app/args.zig, src/app/cli.zig; cause: remaining user-visible gaps vs pi in rpc/session surface (mode alias, rpc envelope compatibility, richer session command payloads); fix: implement each missing surface with tests and docs updates; proof: full test/build matrix passes.
