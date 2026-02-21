---
title: Add session event schema and codecs
status: closed
priority: 1
issue-type: task
created-at: "2026-02-20T21:25:57.619044+01:00"
closed-at: "2026-02-20T22:08:06+01:00"
close-reason: added versioned session event schema and JSON codecs
blocks:
  - pz-add-provider-contract-665ba083
---

Context: PLAN.md:28, src/core/session/schema.zig; cause: event persistence format is not formalized; fix: define event union + json codecs + versioning field; deps: pz-add-provider-contract-665ba083,pz-add-tool-contract-85ba867a,pz-add-mode-and-a8ac8ddb; verification: schema roundtrip tests pass.
