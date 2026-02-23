---
title: Implement ask-questions tool in TUI
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-23T13:30:49.274208+01:00\\\"\""
closed-at: "2026-02-23T13:30:52.267290+01:00"
close-reason: completed
---

Files: src/core/tools/{mod,builtin}.zig, src/core/loop.zig, src/app/runtime.zig, src/app/cli.zig; cause: no interactive tool for structured clarification; fix: add ask tool schema + runtime hook + TUI questionnaire callback and tests; why: planning workflows need structured user input.
