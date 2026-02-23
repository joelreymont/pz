---
title: Fix Ctrl-K and multiline input
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T21:44:20.074906+01:00\""
closed-at: "2026-02-23T21:46:50.518469+01:00"
---

Root-cause Ctrl-K not deleting to end-of-line in TUI editor; implement correct emacs kill behavior and verify multiline input parity with tests.
