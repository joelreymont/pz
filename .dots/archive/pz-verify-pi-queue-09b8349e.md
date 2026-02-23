---
title: Verify pi queue/steer UX
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T21:15:55.412669+01:00\""
closed-at: "2026-02-23T21:16:47.499511+01:00"
close-reason: verified pi queue/steer UX and identified pz gaps
---

Full context: /Users/joel/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/dist/modes/interactive/interactive-mode.js:1500,2148,2391 and /Users/joel/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/dist/core/agent-session.js:496,526. Cause: need source-backed parity for Enter/Alt+Enter/Alt+Up behavior during streaming and queued editing. Fix: extract exact behavior and compare with /Users/joel/Work/pizi/src/app/runtime.zig:1545 and input actions in /Users/joel/Work/pizi/src/modes/tui/editor.zig:284.
