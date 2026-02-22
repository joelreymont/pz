---
title: Startup info display
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T10:26:59.992685+01:00\""
closed-at: "2026-02-22T10:34:36.888211+01:00"
close-reason: "done: discoverPaths in context.zig, startup loop shows each file via infoText (dim color)"
---

Pi displays what files it reads upon startup in yellow (CLAUDE.md, context files). pz loads context but does not display what it found. Fix: after context.load, show discovered files as infoText in transcript. File: runtime.zig runTui
