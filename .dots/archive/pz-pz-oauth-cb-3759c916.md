---
title: pz oauth callback server
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-24T07:44:59.797736+01:00\""
closed-at: "2026-02-24T07:45:02.125319+01:00"
close-reason: Implemented callback listener + OAuth flow and validated via zig tests/build test
---

Full context: /Users/joel/Work/pizi/src/core/providers/oauth_callback.zig:1, /Users/joel/Work/pizi/src/core/providers/auth.zig:183, /Users/joel/Work/pizi/src/app/runtime.zig:2934; cause: /login anthropic lacked local callback listener and browser completion path; fix: add reusable localhost OAuth callback listener, dynamic redirect_uri OAuth start, callback completion with state verification, parser coverage for URL/raw query/code#state, and actionable CLI errors; proof: zig test src/core/providers/oauth_callback.zig, zig test src/core/providers/auth.zig, zig build test --summary failures all pass
