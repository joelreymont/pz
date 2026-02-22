---
title: Startup info display
status: open
priority: 2
issue-type: task
created-at: "2026-02-22T10:26:59.992685+01:00"
---

Pi displays what files it reads upon startup in yellow (CLAUDE.md, context files). pz loads context but does not display what it found. Fix: after context.load, show discovered files as infoText in transcript. File: runtime.zig runTui
