---
title: Upgrade Color to truecolor
status: closed
priority: 2
issue-type: task
created-at: "\"\\\"2026-02-21T22:03:46.966120+01:00\\\"\""
closed-at: "2026-02-21T22:06:19.375114+01:00"
close-reason: done
---

Step 1: Change frame.Color from enum(u5) to union(enum){default,idx:u8,rgb:u24}. Update Style.eql, render.zig writeStyle, all call sites. frame.zig, render.zig
