# pz Architecture

## Layers

```
app/    → CLI parsing, config, runtime dispatcher
core/   → Agent loop, providers, tools, sessions
modes/  → TUI, print, JSON, RPC output handlers
```

Flow: `main → app.run → runtime.exec → core.loop → provider/tools → mode sink`

## Files

**app/**: `args.zig` (CLI parser, Mode enum) · `cli.zig` (command dispatch) · `config.zig` (env → .pz.json → ~/.pi/agent/settings.json) · `runtime.zig` (mode dispatcher, ~3000 lines). `cli.Run` = resolved command (mode, prompt, model, provider, tool mask, session config).

**core/**: `loop.zig` (agent loop) · `context.zig` (AGENTS.md discovery)

**core/providers/**: `contract.zig` (Provider/Stream vtables, Req, Msg, Part, Ev, Role, StopReason) · `anthropic.zig` (HTTPS+SSE) · `openai.zig` (HTTPS+SSE Responses API) · `proc_transport.zig` (subprocess stdin/stdout) · `first_provider.zig` (retry+fallback) · `retry.zig` · `stream_parse.zig` · `streaming.zig` · `types.zig` (error taxonomy) · `auth.zig`

**core/tools/**: `builtin.zig` (registry, bitmask dispatch, 7 tools) · `registry.zig` (comptime registry) · `runtime.zig` (event wrapper) · `read.zig` · `write.zig` · `bash.zig` · `edit.zig` · `grep.zig` · `find.zig` · `ls.zig` · `output.zig` (truncation)

**core/session/**: `schema.zig` (JSONL codec v1) · `reader.zig` · `writer.zig` · `fs_store.zig` · `null_store.zig` · `compact.zig` · `export.zig` · `selector.zig` · `path.zig`

**modes/tui/**: `harness.zig` (Ui coordinator) · `frame.zig` (cell grid) · `render.zig` (diff renderer) · `editor.zig` (input buffer) · `input.zig` (raw terminal parser) · `transcript.zig` (message blocks) · `panels.zig` (footer) · `overlay.zig` (modals) · `markdown.zig` · `syntax.zig` · `theme.zig` · `mouse.zig` (SGR 1006) · `term.zig` (raw mode, SIGWINCH) · `termcap.zig` · `wcwidth.zig` · `vscreen.zig` (test helper) · `fixture.zig`

**modes/print/**: `run.zig` · `format.zig` · `errors.zig`

## Agent Loop

```
run(opts) → replay(sid) → push prompt → turn loop:
  check cancel → build Req → provider.start(Req) → Stream
  stream: next()→Ev → push mode + store + history
  tool_call: registry.run() → Result → store + history
  stop.reason==tool → continue, else break
```

## Provider Contract

```
Provider.start(Req) → Stream.next() → ?Ev
Ev = text | thinking | tool_call | tool_result | usage | stop | err
```

Impls: `anthropic.zig` (HTTPS+SSE), `openai.zig` (HTTPS+SSE), `proc_transport.zig` (subprocess, --provider-cmd)

## Tool Dispatch

Comptime table lookup → bitmask check → emit start → run → emit finish. Mask: `u8`, one bit per tool.

## Session Format

Append-only JSONL: `{"version":1,"at_ms":N,"data":{...}}`. Events: noop, prompt, text, thinking, tool_call, tool_result, usage, stop, err. Store vtable: append/replay.

## TUI Rendering

```
Input → Editor → Transcript/Panels → Frame (w×h cells) → Renderer (diff) → Terminal
```

Frame: cell = codepoint(u21) + style. Renderer: diff prev/next, emit CUP+style for changed runs. DEC 2026 synchronized output.

Layout: transcript (scrollable) | border+status | editor (1 row, h-scroll) | border | footer (2 rows: cwd+branch, turns+tokens+cost+model)

## Input Pipeline

Raw mode (VTIME=100ms) → CSI/SS3/Ctrl/Alt/Paste/Mouse parsing → Key → editor.apply() → Action → runtime handler

## Key Patterns

- **Vtable polymorphism**: `ctx: *anyopaque` + `vt: *const Vt` + comptime `from()`. Used by Provider, Stream, SessionStore, ModeSink, Tool Registry.
- **Arena allocation**: Global (session lifetime) + per-turn (freed after each round-trip).
- **Bitmask tools**: `u8` mask, one bit per tool kind.
- **Event persistence**: Every Ev displayed + persisted simultaneously. Session = replayable event log.
- **Comptime dispatch**: StaticStringMap / comptime arrays for slash commands, tools, keys, stop reasons.

## Cancellation

Background InputWatcher thread polls stdin for ESC → atomic flag → loop checks + breaks.

## Build

```
zig build          # binary
zig build test     # ~385 tests
```

Tests: inline per file, `all_tests.zig` (core), `app_runtime_tests.zig` (mock providers), `fixture.zig`/`vscreen.zig` (TUI assertions), ohsnap (snapshots), zcheck (property tests).
