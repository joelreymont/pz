---
title: "DRY: extract shared word-boundary scan"
status: open
priority: 2
issue-type: task
created-at: "2026-02-23T09:21:37.766807+01:00"
---

lastWordStart duplicated in harness.zig:372 and runtime.zig:842,2307. Extract to editor.zig or shared util.
