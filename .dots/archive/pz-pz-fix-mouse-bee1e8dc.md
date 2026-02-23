---
title: pz-fix-mouse-selection
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T21:09:49.932362+01:00\""
closed-at: "2026-02-23T21:09:54.761064+01:00"
close-reason: done
---

Mouse selection in terminal was blocked because Renderer.setup enabled mouse tracking (?1000h/?1006h). Removed mouse-enable from setup in /Users/joel/Work/pizi/src/modes/tui/render.zig, kept cleanup reset, and added setup/cleanup regression tests.
