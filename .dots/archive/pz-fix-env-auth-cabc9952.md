---
title: Fix env auth fallback
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T17:26:27.555026+01:00\""
closed-at: "2026-02-23T17:31:33.464527+01:00"
---

Root cause: native provider init only loaded ~/.pi auth.json and ignored ANTHROPIC_API_KEY/ANTHROPIC_OAUTH_TOKEN, causing misleading provider_cmd error. Fix src/core/providers/auth.zig env precedence + src/app/runtime.zig fallback message; add regression tests; patch release.
