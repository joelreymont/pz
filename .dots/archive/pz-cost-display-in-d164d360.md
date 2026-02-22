---
title: Cost display in status bar
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T17:21:11.099765+01:00\""
closed-at: "2026-02-22T17:28:01.390099+01:00"
---

Add cumulative cost tracking to status bar. Pi shows $0.046 (sub). Need: 1) price table per model (claude-opus-4-6 etc) with in/out/cache rates, 2) accumulate cost across usage events in Panels, 3) render as $N.NNN in footer line 2. Files: panels.zig (render + state), contract.zig (cost field in Usage or separate accumulator).
