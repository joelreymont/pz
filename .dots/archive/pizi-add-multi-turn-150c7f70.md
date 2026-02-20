---
title: Add multi-turn tui input loop
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"\\\\\\\"2026-02-21T18:26:33.270203+01:00\\\\\\\"\\\"\""
closed-at: "2026-02-21T18:26:36.388359+01:00"
close-reason: completed
---

Context: tui runtime consumed only one prompt; cause: single resolvePrompt call; fix: add stdin-driven line loop with loop-backed turns and add tests for sequential prompts.
