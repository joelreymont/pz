---
title: Add provider stream property tests
status: closed
priority: 1
issue-type: task
created-at: "\"\\\"2026-02-20T21:25:57.739600+01:00\\\"\""
closed-at: "2026-02-20T23:56:56.272091+01:00"
close-reason: completed
blocks:
  - pizi-add-cancellation-and-842dc0d4
---

Context: PLAN.md:86, test/provider_prop_*; cause: stream parser edge cases are under-covered; fix: add fuzz/property tests for chunk boundaries/errors; deps: pizi-add-cancellation-and-842dc0d4; verification: property tests pass with seeded runs.
