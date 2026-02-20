---
title: pizi-provider-json-rpc-parity
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T19:18:37.081216+01:00\""
closed-at: "2026-02-21T19:18:46.080864+01:00"
close-reason: completed
---

Full context: src/app/runtime.zig, src/app/cli.zig; cause: provider/config/runtime wiring and interactive command surface were partially implemented; fix: wire provider labels through loop and complete slash/RPC command surface plus help/runtime tests; proof: zig test src/all_tests.zig, zig build, zig build test all pass.
