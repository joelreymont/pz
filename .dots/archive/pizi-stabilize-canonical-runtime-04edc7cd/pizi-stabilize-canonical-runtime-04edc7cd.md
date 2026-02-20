---
title: Stabilize canonical runtime path
status: closed
priority: 1
issue-type: task
created-at: "\"2026-02-21T18:32:41.889740+01:00\""
closed-at: "2026-02-21T18:42:00.400762+01:00"
close-reason: completed
---

Context: app/runtime embeds built-in tool registry and wrappers; cause: runtime concerns leak into app layer and duplicate core logic; fix: move built-in tool runtime into core/tools, consume from app runtime, and tighten turn semantics with tests.
