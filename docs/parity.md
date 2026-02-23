# Pi Parity Spec

## Scope

This document defines user-visible behavior parity targets between `pz` and `pi`.
Parity is measured at the terminal UX and command semantics level, not internal implementation.

## Command Semantics

### Slash Commands

`pz` must preserve command intent and output classes for:

1. `/help`
2. `/model`
3. `/provider`
4. `/tools`
5. `/bg run|list|show|stop`
6. `/session`
7. `/new`
8. `/resume`
9. `/fork`
10. `/compact`
11. `/settings`
12. `/upgrade`

For each command:

1. Success emits a deterministic, parseable line/message.
2. Invalid usage emits stable usage text.
3. State-changing commands update footer/status immediately.

## Background Jobs

### Lifecycle

1. Start returns `id`, `pid`, and log path.
2. Running jobs update footer counters.
3. Exit emits completion notification with final state and code/error.
4. Stopping a done/missing job is explicit (`already done`/`not found`).

### Crash Recovery

1. Launch and exit are persisted in append-only journal entries.
2. On restart, unclosed launch entries are replayed.
3. Replayed stale jobs are terminated and marked cleaned.
4. Journal replay after recovery contains no stale active entries.

## Status/Footer

Footer must expose:

1. Project path (with home shortening)
2. Active branch/bookmark
3. Model and provider
4. Thinking level indicator
5. Turn/token/cost/context utilization
6. Background counters (`L`, `R`, `D`) and spinner while running

## Rendering Parity

Deterministic rendering requirements:

1. Stable frame output for fixed terminal size and seed.
2. Spinner/state transitions produce predictable frame deltas.
3. Overlay navigation (up/down/enter/esc) is deterministic.
4. Prompt/tool/result transcript ordering is stable.

## Ask Tool Parity

`ask` tool behavior:

1. Accepts one or more questions with options.
2. In TUI, renders a per-question overlay with previous/next navigation and a final submit action.
3. Each question can choose an option or `Type something else` and enter custom text inline.
4. `Esc`/`Ctrl-C` cancels the questionnaire and returns to the prompt.
5. Returns structured JSON with `cancelled` and `answers`.
6. In non-interactive mode, returns explicit unsupported error.

## Error Surface

All user-facing failures must be typed and explicit:

1. No silent fallback for missing tools/invalid args.
2. No swallowed bg process errors.
3. Recovery/cleanup failures must still produce deterministic output.

## Test Contract

Parity test coverage must include:

1. Unit tests for parser/tool dispatch and structured errors.
2. Snapshot tests for footer/render states.
3. Integration tests for slash commands and bg lifecycle.
4. Journal replay/recovery tests.
5. Ask tool interactive + non-interactive behavior tests.
