---
title: Fix openExtEditor temp file race
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-22T16:00:44.974982+01:00\""
closed-at: "2026-02-22T16:05:20.848937+01:00"
---

runtime.zig:2099-2117 — Uses fixed /tmp/pz-edit.txt, race/clobber risk. Use unique temp files + typed errors.
