---
title: Show auto only on compaction
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T20:19:09.004469+01:00\""
closed-at: "2026-02-23T20:20:09.111107+01:00"
close-reason: completed
---

Full context: src/modes/tui/panels.zig currently appends (auto) whenever ctx limit is known; user wants indicator only when compaction triggers. Wire runtime compaction event to panels and render transient compaction badge only when triggered, with tests.
