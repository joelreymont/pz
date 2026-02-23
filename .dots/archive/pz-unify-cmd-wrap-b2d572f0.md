---
title: Unify command + wrap logic
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T11:29:37.546278+01:00\""
closed-at: "2026-02-23T11:37:25.621389+01:00"
close-reason: implemented and tested
---

Full context: src/app/runtime.zig duplicate slash/rpc command semantics and src/modes/tui/harness.zig duplicated wrap loops; cause: drift-prone duplicated implementations; fix: extract shared helpers and add parity tests for both paths.
