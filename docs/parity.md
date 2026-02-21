# pz Feature Parity

Tracks user-visible harness parity targets and proof points.

## Runtime Modes

- [x] `tui` interactive mode
  - Proof: `src/app/runtime.zig` tests
- [x] `print` headless mode
  - Proof: `src/app/runtime.zig`, `src/modes/print/run.zig`
- [x] `json` headless event stream mode
  - Proof: `src/app/runtime.zig:test \"runtime json mode emits JSON lines for loop events\"`
- [x] `rpc` stdin/stdout command mode
  - Proof: `src/app/runtime.zig:test \"runtime rpc mode handles session model prompt and quit commands\"`

## Session Surface

- [x] default auto session creation
- [x] `--continue` / `--resume`
- [x] `--session <ID|PATH>`
- [x] `--no-session`
- [x] runtime slash/RPC session controls: `new`, `resume`, `session`, `tree`, `fork`, `compact`
  - Proof: `src/app/args.zig`, `src/app/runtime.zig`

## Model/Provider Surface

- [x] `--model <MODEL>`
- [x] `--provider <PROVIDER>`
- [x] `--provider-cmd <CMD>`
- [x] auto-import pi defaults from `~/.pi/agent/settings.json`
  - Proof: `src/app/config.zig:test "config auto imports pi settings from home"`
- [x] `/model` and `/provider` commands in TUI
- [x] `model` and `provider` commands in RPC
- [x] `/tools` and `tools` commands for live tool-surface control
  - Proof: `src/app/runtime.zig:test \"runtime tui tools command updates tool availability per turn\"`
  - Proof: `src/app/runtime.zig:test \"runtime rpc tools command updates tool availability per turn\"`
- [x] provider label forwarded into provider request payload
  - Proof: `src/app/args.zig`, `src/app/config.zig`, `src/app/runtime.zig`, `src/core/providers/first_provider.zig`
- [x] TUI status renders model + provider identity
  - Proof: `src/modes/tui/panels.zig:test \"panels render model status and usage indicators\"`

## Tools

- [x] core built-ins: `read`, `write`, `bash`, `edit`
- [x] extra built-ins: `grep`, `find`, `ls`
- [x] `--tools <LIST>` and `--no-tools` masking
  - Proof: `src/core/tools/*`, `src/app/args.zig`, `src/app/runtime.zig`

## Explicit Non-Parity (By Design)

- [ ] SDK integration
- [ ] extension/plugin ecosystem

These are out of scope for Zig-first `pz` unless explicitly requested.
