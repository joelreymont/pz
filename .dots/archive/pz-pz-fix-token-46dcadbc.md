---
title: pz-fix-token-counters
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T21:08:47.024735+01:00\""
closed-at: "2026-02-23T21:08:50.061445+01:00"
close-reason: done
---

Footer token counters were per-turn not cumulative, causing barely changing numbers. Updated /Users/joel/Work/pizi/src/modes/tui/panels.zig to accumulate tot_in/tot_out/tot_cr/tot_cw across usage events while preserving cum_tok for context gauge; updated /Users/joel/Work/pizi/src/core/loop.zig mapProviderEv to persist cache_read/cache_write in session events; added regression tests for cumulative footer totals and usage cache mapping.
