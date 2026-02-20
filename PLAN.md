# pizi Reimplementation Plan

## Objective

Implement a standalone Zig coding-agent harness with TUI.
Inspired by pi, not compatible with pi.

## Architecture Targets

- Single Zig project
- Clear split:
  - `core` (agent loop, session, tools, providers)
  - `modes` (interactive TUI, print)
  - `app` (CLI entrypoints, config)
- Deterministic session persistence
- Streaming-first execution model

## Phases

## Phase 0: Foundation (Sequential)

1. Bootstrap Zig project, build/test scripts, CI baseline.
2. Define core interfaces:
   - `Provider`
   - `Tool`
   - `SessionStore`
   - `Mode`
3. Define session/event schema for `pizi`.

## Phase 1: Parallel Core Tracks

Run in separate `jj` workspaces.

### Track A: Session + Persistence

- JSONL session writer/reader
- message/event model
- compaction and retry state storage

### Track B: Tool Runtime

- `read`, `bash`, `edit`, `write`
- truncation and output handling
- tool-call/result lifecycle

### Track C: Provider Streaming

- provider abstraction
- first provider integration
- streaming parser and error taxonomy

## Phase 2: Parallel Mode Tracks

Run in separate `jj` workspaces.

### Track D: TUI Runtime

- terminal renderer
- input/editor
- streaming message view
- tool execution panels
- model/status indicators
- keymap system

### Track E: Headless Print Mode

- non-interactive prompt mode
- deterministic stdout formatting

### Track F: CLI Surface

- argument parsing
- config discovery
- mode dispatch

## Phase 3: Integration

1. Wire tracks A-F into end-to-end loop.
2. Add cancellation, retry, compaction triggers.
3. Add robust error reporting.

## Phase 4: Hardening

1. Golden tests for session replay.
2. Tool contract tests.
3. Provider stream fuzz/property tests.
4. TUI interaction tests in controlled terminal size.
5. Performance pass on hot paths.

## Parallel Execution Model

## Workspace Pattern

- Root: `/Users/joel/Work/pizi`
- Workspaces:
  - `/Users/joel/Work/pizi-a`
  - `/Users/joel/Work/pizi-b`
  - `/Users/joel/Work/pizi-c`
  - etc.

## Commands

1. Create:
   - `jj workspace add ../pizi-a`
2. Work independently:
   - each workspace owns a file set
3. Reconcile:
   - rebase/squash into integration change
4. Cleanup:
   - `jj workspace forget pizi-a`

## Ownership Matrix (Initial)

- Track A owns: `src/core/session/*`
- Track B owns: `src/core/tools/*`
- Track C owns: `src/core/providers/*`
- Track D owns: `src/modes/tui/*`
- Track E owns: `src/modes/print/*`
- Track F owns: `src/app/*`

No cross-track edits without explicit reassignment.

## Milestone Exit Criteria

## M1

- CLI runs and writes/reads sessions.

## M2

- Tool calls execute via agent loop.

## M3

- TUI interactive prompt fully usable.

## M4

- Stable streaming, retry, compaction behavior.

## M5

- Test suite green and performance baseline recorded.

## Execution Status (February 21, 2026)

- [x] Phase 0 complete
- [x] Phase 1 complete
- [x] Phase 2 complete
- [x] Phase 3 complete
- [x] Phase 4 complete
- [x] M1-M5 achieved

Detailed user-visible parity tracking lives in `docs/parity.md`.
