---
title: pz strong oauth tests
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-24T08:01:08.715454+01:00\""
closed-at: "2026-02-24T08:06:48.850925+01:00"
close-reason: Added stronger OAuth and callback tests across providers and malformed-edge cases; all auth/callback/report/build tests pass
---

Full context: auth + callback + runtime login flows need stronger regression coverage for provider-specific redirect/path/state/api-key classification and malformed callback payloads; cause: cross-provider oauth expansion increases edge-case surface; fix: add comprehensive unit/integration tests for openai+anthropic oauth parsing/start URLs/callback handling/login classification; proof: zig test targets and zig build test pass
