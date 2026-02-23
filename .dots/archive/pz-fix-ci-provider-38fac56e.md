---
title: Fix CI provider test
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T17:36:28.287170+01:00\""
closed-at: "2026-02-23T17:36:32.973238+01:00"
---

CI ubuntu failed because runtime no-provider test asserted exact phrase provider unavailable, but AuthNotFound path emits anthropic credentials missing. Broaden assertion to auth hint/provider hint and rerun tests.
