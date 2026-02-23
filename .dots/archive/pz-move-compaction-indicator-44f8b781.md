---
title: Move compaction indicator to status border
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T20:21:14.252303+01:00\""
closed-at: "2026-02-23T20:26:55.486065+01:00"
close-reason: implemented
---

Full context: remove footer '(auto)' label in src/modes/tui/panels.zig and show compaction activity indicator in border status line above input in src/modes/tui/harness.zig using blink/spinner semantics tied to auto compact trigger.
