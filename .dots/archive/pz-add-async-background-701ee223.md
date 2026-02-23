---
title: Add async background tool
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T11:58:25.793844+01:00\""
closed-at: "2026-02-23T12:12:32.155034+01:00"
close-reason: completed
---

Full context: add a tool to launch one or multiple background commands, capture stdout+stderr to mktemp file, and report completion when child exits without prompt blocking; wire into runtime loop/tool registry and tests; use event-driven process exit notifications, not polling.
