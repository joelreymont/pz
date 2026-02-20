# pizi

`pizi` is a Zig-first coding-agent harness with an integrated terminal UI.

It is inspired by pi, but intentionally not API- or format-compatible.

## Scope

- CLI harness
- Interactive TUI
- Headless print mode
- Headless JSON mode
- RPC stdin/stdout command mode
- Core tools: `read`, `bash`, `edit`, `write`
- Extra built-ins: `grep`, `find`, `ls`
- Session persistence
- Streaming model responses
- Session control: continue/resume/explicit session IDs and paths
- Interactive slash command surface (`/model`, `/provider`, `/tools`, `/session`, `/tree`, `/fork`, `/compact`, ...)

## Non-Goals

- Backward compatibility with pi
- Web UI
- Slack bot integrations
- Multi-package monorepo layout
- SDK/extension ecosystem parity

## Status

Core runtime, tooling, and mode surface are implemented with tests.

See `PLAN.md` for execution order and `docs/parity.md` for feature-level parity tracking.
