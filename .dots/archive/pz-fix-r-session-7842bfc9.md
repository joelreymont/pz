---
title: Fix -r session restore UX
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T20:51:01.845306+01:00\""
closed-at: "2026-02-23T20:56:59.350751+01:00"
close-reason: restored session replay on resume paths
---

Full context: pz -r resumes SID but does not repopulate transcript/panel state in TUI. Implement replay-based restoration on startup and on /resume/overlay session switch, with tests proving prior session content is visible.
