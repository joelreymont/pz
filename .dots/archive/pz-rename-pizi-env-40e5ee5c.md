---
title: Rename PIZI env vars to PZ
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T10:26:59.981043+01:00\""
closed-at: "2026-02-22T10:27:30.178275+01:00"
close-reason: "done: PIZI_PROVIDER_CMD→PZ_PROVIDER_CMD, PIZI_THEME→PZ_THEME, PIZI_BASH_ENV→PZ_BASH_ENV"
---

PIZI_PROVIDER_CMD, PIZI_THEME, PIZI_BASH_ENV → PZ_PROVIDER_CMD, PZ_THEME, PZ_BASH_ENV. Files: runtime.zig:80, theme.zig:175, bash.zig:472,484
