---
title: TUI hides thinking by default
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T10:26:59.984226+01:00\""
closed-at: "2026-02-22T10:29:56.342250+01:00"
close-reason: "done: show_thinking=false default, collapsed 'Thinking...' label, blockDisplayText helper, fixture+transcript tests updated"
---

Pi hides thinking content by default, shows 'Thinking...' label. pz shows full [thinking] text. Fix: show_thinking=false default in Transcript, render 'Thinking...' italic label instead of full content when hidden. File: transcript.zig:57,106
