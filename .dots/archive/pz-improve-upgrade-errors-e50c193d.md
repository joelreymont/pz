---
title: Improve upgrade errors
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T17:41:53.294420+01:00\""
closed-at: "2026-02-23T17:49:26.694582+01:00"
---

User sees opaque ReleaseApiFailed from pz --upgrade. Add structured actionable error reporting for update flow including network/HTTP/status/body/asset/platform cases; wire into CLI and TUI; add tests; keep messages user-focused.
