---
title: pizi-add-rpc-type-id-compat-layer
status: closed
priority: 2
issue-type: task
created-at: "\"2026-02-21T20:07:00.033993+01:00\""
closed-at: "2026-02-21T20:12:00.993640+01:00"
close-reason: completed
---

Full context: src/app/runtime.zig runRpc; cause: rpc currently requires cmd-style requests and does not roundtrip request ids; fix: accept cmd or type command key, add id passthrough in rpc responses, and support get_state/get_commands/new_session aliases; proof: runtime rpc tests for cmd and type envelopes pass.
