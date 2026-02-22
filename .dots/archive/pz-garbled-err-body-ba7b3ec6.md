---
title: Garbled error body (gzip)
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T22:10:27.879269+01:00\""
closed-at: "2026-02-22T22:11:41.535640+01:00"
---

API error responses are gzip-compressed but pz reads raw bytes. Use readerDecompressing() in anthropic.zig:112 for error body. File: src/core/providers/anthropic.zig:110-118
