---
title: pz-add-interactive-mode-alias
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T20:07:00.030532+01:00\""
closed-at: "2026-02-21T20:12:00.989965+01:00"
close-reason: completed
---

Full context: src/app/args.zig, src/app/config.zig, src/app/cli.zig; cause: pi surface uses interactive mode naming while pz accepts tui only; fix: accept interactive as mode alias and document it in help; proof: arg/config/cli tests cover alias parsing.
