---
title: pz-auth-refresh-provider-scope
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-24T09:13:05.778816+01:00\""
closed-at: "2026-02-24T09:19:51.055097+01:00"
---

Refactor src/core/providers/auth.zig refresh OAuth to provider-scoped API and update provider clients; remove Anthropic-only refresh path and keep explicit errors; add tests for provider-aware behavior and no masked errors.
