---
title: Implement steering (CLAUDE.md loading)
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-22T09:43:14.873221+01:00\\\"\""
closed-at: "2026-02-22T10:05:59.769672+01:00"
close-reason: "Implemented: context.zig discovers AGENTS.md/CLAUDE.md (global ~/.pz, cwd upward), system_prompt threaded through loop, --system-prompt and --append-system-prompt CLI flags"
---

Pi loads context files from: ~/.pi/agent/CLAUDE.md (global), ./.pi/CLAUDE.md (project), parent dirs (ancestor traversal). Merged into system prompt as Project Context section. Also needs --system-prompt and --append-system-prompt CLI flags. Files: src/app/runtime.zig, src/app/args.zig, new src/core/context.zig. Ref: pi resource-loader.ts, system-prompt.ts
