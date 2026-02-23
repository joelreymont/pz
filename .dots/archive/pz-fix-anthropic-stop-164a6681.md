---
title: Fix anthropic stop/options
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T11:29:37.538100+01:00\""
closed-at: "2026-02-23T11:37:25.614808+01:00"
close-reason: implemented and tested
---

Full context: src/core/providers/anthropic.zig mapStopReason/buildBody; cause: canceled/err collapsed to done and temp/top_p/stop opts omitted; fix: align stop mapping with contract and serialize opts with unit tests.
