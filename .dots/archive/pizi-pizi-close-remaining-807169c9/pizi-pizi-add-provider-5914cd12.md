---
title: pizi-add-provider-to-tui-status
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T19:43:02.567834+01:00\""
closed-at: "2026-02-21T19:46:22.454900+01:00"
close-reason: completed
---

Full context: src/modes/tui/panels.zig:42,173 and src/modes/tui/harness.zig:21,27 and src/app/runtime.zig:322; cause: status panel only tracks model, provider not visible; fix: store/render provider in panels and initialize/update it via runtime; proof: panels/harness/runtime tests assert provider text and model/provider updates.
