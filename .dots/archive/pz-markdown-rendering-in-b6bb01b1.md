---
title: Markdown rendering in transcript
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-21T22:46:17.229080+01:00\""
closed-at: "2026-02-21T23:25:05.549584+01:00"
close-reason: done
---

Parse markdown in AI response text blocks: headings (bold+color), code blocks (bg+border), inline code (accent color), links (underline+color), bullets/numbered lists (indent+bullet color), blockquotes (dim+prefix). Add markdown parser to transcript.zig that processes block text before rendering. Use theme.md_* colors. Files: transcript.zig (new md parser ~200-300 lines)
