---
title: pizi-expose-tools-in-settings-output
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T19:43:02.575371+01:00\""
closed-at: "2026-02-21T19:46:22.462301+01:00"
close-reason: completed
---

Full context: src/app/runtime.zig:700,778,546; cause: session/settings outputs omit active tool surface; fix: include enabled tools in /settings and rpc session/tools responses; proof: runtime tests assert tools fields.
