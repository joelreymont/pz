---
title: Double-width CJK character support
status: closed
priority: 3
issue-type: task
created-at: "\"2026-02-21T22:46:35.083911+01:00\""
closed-at: "2026-02-21T23:24:51.103229+01:00"
close-reason: wcwidth.zig with Unicode EAW table, frame.write uses width
---

Replace 1-codepoint=1-column assumption with proper Unicode East Asian Width lookup. Affects WrapIter word wrap, cpCount, frame.write, clipCols. Need wcwidth equivalent - either comptime table from Unicode data or small lookup. Files: transcript.zig (wrap/count), frame.zig (write width)
