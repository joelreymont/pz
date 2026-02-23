---
title: Fix editor wide glyph cells
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T11:29:37.534439+01:00\""
closed-at: "2026-02-23T11:37:25.611570+01:00"
close-reason: implemented and tested
---

Full context: src/modes/tui/harness.zig drawEditor writes wide glyph with Frame.set only; cause: missing Frame.wide_pad trailing cell; fix: emit wide pad consistently and add regression tests on editor row rendering.
