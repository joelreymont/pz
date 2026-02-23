---
title: Build shared error reporter
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T17:44:43.529337+01:00\""
closed-at: "2026-02-23T17:49:26.699422+01:00"
---

Implement centralized user-facing error formatting with category/reason/next-step guidance, then wire slash commands, RPC command errors, and top-level command dispatch to use it instead of raw @errorName strings.
