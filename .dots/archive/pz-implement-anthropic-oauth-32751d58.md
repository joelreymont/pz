---
title: Implement Anthropic OAuth login
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T21:58:57.717450+01:00\""
closed-at: "2026-02-23T22:02:38.402366+01:00"
close-reason: implemented browser OAuth flow and tests
---

Context: /Users/joel/Work/pizi/src/core/providers/auth.zig and /Users/joel/Work/pizi/src/app/runtime.zig. Cause: /login anthropic only saved API keys and did not support browser OAuth. Fix: add PKCE URL generation, browser launch, code/state parsing, token exchange, and runtime command wiring while preserving API key path. Verification: zig test on auth and runtime slices.
