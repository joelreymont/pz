---
title: pizi-rename-binary-to-pz
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T20:07:23.793800+01:00\""
closed-at: "2026-02-21T20:12:01.006679+01:00"
close-reason: completed
---

Full context: build.zig and src/app/cli.zig; cause: executable/help/version still use pizi binary name; fix: rename built binary artifact to pz and update user-facing usage/version strings and tests; proof: full test/build matrix passes with pz naming.
