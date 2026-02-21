---
title: Mouse support + scroll wheel
status: closed
priority: 3
issue-type: task
created-at: "\"2026-02-21T22:46:46.344297+01:00\""
closed-at: "2026-02-21T23:35:16.847553+01:00"
close-reason: SGR mouse protocol, scroll state in transcript, mouse enable/disable in renderer
---

Parse xterm mouse protocol (SGR 1006 mode) for scroll wheel events. Enable with \x1b[?1006h on startup. Translate wheel-up/down into transcript scroll offset changes instead of always auto-scrolling to bottom. Add manual scroll state to Transcript. Files: input handling (new), transcript.zig (scroll state), render.zig (mouse enable/disable)
