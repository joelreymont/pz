---
title: Add mode dispatch wiring
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.711436+01:00\\\"\""
closed-at: "2026-02-20T23:37:46.614705+01:00"
close-reason: completed
blocks:
  - pz-add-config-discovery-0f0a1530
---

Context: PLAN.md:74, src/app/main.zig; cause: CLI cannot route to selected mode; fix: wire dispatch to tui and print runtimes; deps: pz-add-config-discovery-0f0a1530,pz-add-print-mode-1bb5c02a,pz-add-terminal-frame-3c994697; verification: dispatch smoke tests pass.
