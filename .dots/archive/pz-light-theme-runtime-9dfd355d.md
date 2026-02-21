---
title: Light theme + runtime theme switching
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T22:46:29.021145+01:00\""
closed-at: "2026-02-21T23:24:51.100057+01:00"
close-reason: Theme struct with dark/light, runtime PIZI_THEME/COLORFGBG detection
---

Add light theme constants from pi's light.json to theme.zig. Add runtime selection via PIZI_THEME env var or config. Theme becomes a struct with named fields instead of top-level consts, selected at init. Files: theme.zig (restructure to support both), harness.zig (load from config/env)
