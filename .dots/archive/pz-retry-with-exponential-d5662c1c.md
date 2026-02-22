---
title: Retry with exponential backoff
status: closed
priority: 3
issue-type: task
created-at: "\"\\\"2026-02-22T09:43:35.194594+01:00\\\"\""
closed-at: "2026-02-22T10:08:36.528384+01:00"
close-reason: Native anthropic retries 429/5xx 3 times with 2s/4s/8s backoff. Proc transport updated to 4 tries, 2s base, 60s max
---

Pi retries failed API calls: enabled=true, maxRetries=3, baseDelayMs=2000, maxDelayMs=60000. Honors server retry-after headers. Need: retry loop in anthropic.zig around HTTP request, check response status codes (429, 5xx), exponential backoff with jitter. Ref: pi settings retry config
