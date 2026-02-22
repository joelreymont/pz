---
title: Remove tools sidebar
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T08:21:06.930849+01:00\""
closed-at: "2026-02-22T08:40:22.605794+01:00"
---

harness.zig: Remove horizontal split. Transcript uses full terminal width. Remove splitToolW, separator rendering, tools panel rendering. panels.zig: Remove renderTools. Theme: Remove tool_title if unused.
