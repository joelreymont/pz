---
title: pz dry oauth auth refactor
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-24T08:01:08.715264+01:00\""
closed-at: "2026-02-24T08:06:48.850051+01:00"
close-reason: Refactored OAuth auth/login flow around shared provider spec and generic begin/complete/exchange helpers; removed provider-specific duplication in runtime
---

Full context: /Users/joel/Work/pizi/src/core/providers/auth.zig and /Users/joel/Work/pizi/src/app/runtime.zig currently duplicate provider OAuth start/complete/token-exchange logic; cause: adding openai oauth mirrored anthropic flow; fix: introduce shared provider-config-driven OAuth helpers and generic runtime login handling to eliminate duplication while preserving provider edge behavior; proof: auth/runtime/report tests plus full zig build test
