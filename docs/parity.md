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

## TUI Display Parity

- [x] startup banner with version, keybindings, context, skills
- [x] cost display ($N.NNN) and subscription indicator (sub)
- [x] prompt caching (cache_control on last system block)
- [x] jj bookmark / git branch in footer
- [x] user prompt echo in transcript
- [x] thinking visible by default
- [x] model selector overlay (ctrl+l)
- [x] tool call display as `$ command`
- [x] ESC cancellation during streaming (InputWatcher thread)
- [x] --max-turns flag
- [x] `/export [path]` session export to markdown
- [x] `/session` rich info (message counts, file, ID)
- [x] `/cost` detailed breakdown (tokens, cache, cost)
- [x] bracketed paste mode (multi-line paste, file drop)
- [x] streaming/tool status indicator on border line
- [x] input history (up/down arrow navigation)
- [x] hardware cursor positioned on editor line
- [x] max_tokens stop reason feedback in transcript
- [x] emacs keybindings (ctrl+a/e/u/w)
- [x] word movement (alt+b/f, ctrl+left/right)
- [x] turn counter in footer
- [x] `/settings` shows system prompt preview
- [x] slash command tab completion
- [x] editor horizontal scrolling (long input)
- [x] Page Up/Down keyboard transcript scrolling
- [x] portable clipboard (pbcopy/xclip/xsel/wl-copy)
- [x] kill ring (ctrl+k/u/w + ctrl+y/alt+y)
- [x] undo/redo (ctrl+z / ctrl+shift+z)
- [x] jump-to-char (ctrl+])
- [x] multi-line editor with visual word-wrap (up to 8 rows)
- [x] slash command preview dropdown with fuzzy matching
- [x] per-command argument completion (model, provider, tools)
- [x] file path completion (Tab for paths, @ mention dropdown)
- [x] inline image rendering (Kitty + iTerm2 protocols)
- [x] model selector overlay (ctrl+l)
- [x] session selector overlay (/resume)
- [x] settings overlay (/settings)
- [x] fork message selector overlay (/fork)
- [x] login/logout overlays with provider selection
- [x] `/login <provider> <key>` direct API key login

## Slash Commands

- [x] `/help`, `/quit`, `/exit`
- [x] `/session`, `/settings`, `/hotkeys`
- [x] `/model <id>`, `/provider <id>`, `/tools [list|all]`
- [x] `/clear`, `/copy`, `/cost`
- [x] `/export [path]` — export to markdown
- [x] `/name <name>`, `/new`, `/resume [id]`, `/tree`, `/fork [id]`
- [x] `/compact`, `/reload`
- [x] `/login`, `/logout`
- [x] `/share` — GitHub gist via `gh gist create`
  - Proof: `src/app/runtime.zig:shareGist`
- [x] `/changelog` — changelog display (placeholder)
  - Proof: `src/app/runtime.zig:handleSlashCommand`
- [x] scoped models — `--models` flag, `enabled_models` config, pi settings import
  - Proof: `src/app/config.zig:test "config models flag sets enabled_models"`

## Explicit Non-Parity (By Design)

- [ ] SDK integration
- [ ] extension/plugin ecosystem

These are out of scope for Zig-first `pz` unless explicitly requested.
