---
title: pizi-add-tools-command-surface
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T19:43:02.571783+01:00\""
closed-at: "2026-02-21T19:46:22.458922+01:00"
close-reason: completed
---

Full context: src/app/runtime.zig:675,625,205,318,400; cause: no /tools or rpc tools command and tool registry is fixed at start; fix: add /tools + rpc tools commands and make TUI/RPC use live runtime tool mask each turn; proof: runtime tests show command output and provider requests reflect updated tool set.
