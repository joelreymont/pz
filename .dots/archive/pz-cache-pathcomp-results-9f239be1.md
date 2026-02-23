---
title: Cache pathcomp results per prefix
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-23T09:21:32.906048+01:00\""
closed-at: "2026-02-23T09:31:54.139838+01:00"
---

pathcomp.list called on every keystroke via updatePreview. Cache: store last prefix+results, invalidate when prefix changes to non-extension of cached prefix.
