---
title: Prompt caching support
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T17:21:16.653648+01:00\""
closed-at: "2026-02-22T17:28:01.394088+01:00"
---

Enable Anthropic prompt caching to get R/W cache tokens in status bar. Need: 1) add cache_control:{type:ephemeral} to system message in request body, 2) verify cache_read/cache_write fields populate from API response (parsing already done in anthropic.zig:259-260). Files: anthropic.zig (request building), panels.zig (already renders R/W when >0).
