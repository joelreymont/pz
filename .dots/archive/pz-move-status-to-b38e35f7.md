---
title: Move status to 2-line footer
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T08:21:12.034203+01:00\""
closed-at: "2026-02-22T08:40:22.609575+01:00"
---

harness.zig: Move status bar from top (y=0) to bottom (y=h-2,h-1). Editor goes to y=h-3. Transcript fills y=0..h-4. panels.zig: Rewrite renderStatus as 2-line footer. Line1: cwd:branch session-name. Line2: ↑in ↓out [pct%/Nk] model thinking-level. All dim. Match pi footer.ts exactly.
