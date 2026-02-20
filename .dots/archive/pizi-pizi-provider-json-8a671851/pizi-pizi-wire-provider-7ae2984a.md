---
title: pizi-wire-provider-label-through-loop
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T19:18:46.056694+01:00\""
closed-at: "2026-02-21T19:18:46.069411+01:00"
close-reason: completed
---

Full context: src/app/runtime.zig:227,917 and src/core/loop.zig:156,351; cause: loop supports provider_label but app runtime paths omitted propagation; fix: pass config/runtime provider label through print/json/tui/rpc turn execution into core.loop.run; proof: runtime provider forwarding regression test passes.
