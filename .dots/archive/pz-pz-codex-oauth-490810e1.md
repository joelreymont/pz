---
title: pz codex oauth browser flow
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-24T07:50:18.332612+01:00\""
closed-at: "2026-02-24T07:50:23.062475+01:00"
close-reason: Implemented OpenAI/Codex callback-server OAuth flow and verified with tests
---

Full context: /Users/joel/Work/pizi/src/core/providers/auth.zig, /Users/joel/Work/pizi/src/app/runtime.zig, /Users/joel/Work/pizi/src/app/report.zig; cause: /login openai was API-key-only while codex/pi uses browser OAuth callback flow; fix: add OpenAI Codex OAuth start/complete/token exchange using reusable callback listener, wire provider-specific /login routing for anthropic+openai, and expand login classification tests; proof: zig test src/core/providers/auth.zig, zig test src/app/report.zig, zig build test --summary failures
