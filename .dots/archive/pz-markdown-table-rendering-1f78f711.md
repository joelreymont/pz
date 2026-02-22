---
title: Markdown table rendering
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T22:45:30.441932+01:00\""
closed-at: "2026-02-22T22:51:52.383245+01:00"
---

Add table detection and rendering to MdRenderer: header rows bold with │ borders, separator rows as ─/┼ box drawing, data rows with │ borders. State tracking for in_table/saw_table_sep. Files: src/modes/tui/markdown.zig
