---
title: pz-native-openai-provider
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-24T09:13:05.723120+01:00\""
closed-at: "2026-02-24T09:19:51.053659+01:00"
---

Implement native OpenAI Responses streaming provider in src/core/providers/openai.zig; integrate runtime provider selection in src/app/runtime.zig; root cause: native path is Anthropic-only causing provider mismatch; proof: runtime init currently instantiates anthropic client only; add tests for parse/body and selection.
