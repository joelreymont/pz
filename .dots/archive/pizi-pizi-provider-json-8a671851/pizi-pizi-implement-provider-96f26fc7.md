---
title: pizi-implement-provider-interactive-surface
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T19:18:46.060334+01:00\""
closed-at: "2026-02-21T19:18:46.072272+01:00"
close-reason: completed
---

Full context: src/app/runtime.zig:384-742; cause: /provider and provider rpc command were placeholders/read-only; fix: implement mutable provider selection in TUI slash and RPC command handlers, include provider in session/settings outputs and help command lists; proof: runtime rpc and slash command tests assert provider command behavior.
