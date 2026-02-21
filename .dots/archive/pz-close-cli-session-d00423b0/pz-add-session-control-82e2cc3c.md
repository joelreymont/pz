---
title: Add session control flags
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T18:43:05.354269+01:00\""
closed-at: "2026-02-21T18:52:24.073231+01:00"
close-reason: completed
---

Full context: src/app/args.zig:1 src/app/cli.zig:1; cause: missing --continue/--resume/--session/--no-session semantics blocks restore/resume workflows; fix: parse/validate flags with strict conflicts and tests; deps: parent.
