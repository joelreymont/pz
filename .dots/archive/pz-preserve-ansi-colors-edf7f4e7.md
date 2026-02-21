---
title: Preserve ANSI colors in tool output
status: closed
priority: 3
issue-type: task
created-at: "\"2026-02-21T22:46:51.844236+01:00\""
closed-at: "2026-02-21T23:30:53.660320+01:00"
close-reason: parseAnsi with SGR->Style mapping, per-span rendering, 288 tests pass
---

Instead of stripping ANSI from tool results, parse and convert to frame.Style colors. Keep stripAnsi as fallback for malformed sequences. Requires mini ANSI parser that maps SGR params to Color values. Files: transcript.zig (replace strip with parse-and-style)
