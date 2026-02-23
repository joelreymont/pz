---
title: pz-release-notify-self-upgrade
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T12:58:48.116725+01:00\""
closed-at: "2026-02-23T12:58:52.119115+01:00"
close-reason: implemented release notice + self-upgrade (CLI/slash/RPC) with updater tests
---

Full context: src/app/version.zig:50 add Check.isDone; src/app/runtime.zig:615 poll until check completes and show update notice with /upgrade hint; src/app/args.zig:59 + src/app/cli.zig:53 + src/app/mod.zig:26 add --upgrade/--self-upgrade and command dispatch; src/app/runtime.zig:1480,1819 add RPC and /upgrade command; src/app/update.zig implement release download/extract/install and edge-case tests; src/modes/tui/cmdprev.zig:39 add upgrade command preview; cause: release notifications could be missed and no self-update path; fix: continuous check + explicit upgrade commands; proof: zig fmt --check, zig build check, zig build test all pass.
