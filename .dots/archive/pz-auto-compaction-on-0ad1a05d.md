---
title: Auto-compaction on context overflow
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T09:43:21.724992+01:00\""
closed-at: "2026-02-22T10:16:33.982208+01:00"
close-reason: "done: autoCompact in runtime.zig triggers at 80% ctx_limit, calls compactSession, shows info in transcript"
---

Pi auto-compacts when context approaches model limit. Triggers: keepRecentTokens (20k default), overflow detection. Need: track cumulative tokens in loop.zig, check against ctx_limit after each turn, invoke compaction when threshold hit. Settings: compaction.enabled, reserveTokens, keepRecentTokens. Ref: pi compaction/
