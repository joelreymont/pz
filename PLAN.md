# pz Reimplementation Plan

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
3. Define session/event schema for `pz`.

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

## Phase 5: TUI Redesign

Replace the fixed-size cell-grid renderer with a line-based scrolling model
matching pi's architecture.

### 5.1 Line-based renderer

- Components return `[][]const u8` (array of styled lines) from `render(width)`.
- TUI diffs line arrays and emits minimal ANSI updates.
- Terminal scrolls naturally; no alternate screen.
- Synchronized output (`?2026h`/`?2026l`) wraps each paint cycle.

### 5.2 Truecolor + theme system

- Replace 16-color `Color` enum with RGB truecolor (`u24`).
- Add 256-color fallback for limited terminals.
- Semantic theme tokens: accent, border, success, error, warning, muted, dim,
  tool backgrounds (pending/success/error), user message bg, markdown colors.
- Theme loaded from JSON (same format as pi, or subset).

### 5.3 Component system

- `Component` interface: `render(width: usize) [][]const u8`.
- Core components: `Container`, `Box` (padding + bg), `Text`, `Spacer`,
  `DynamicBorder` (`─` fill).
- `Markdown` renderer: headings, code blocks with syntax highlighting, bold,
  italic, links, lists.
- `Box` applies background color to full line width (visual grouping).

### 5.4 Layout redesign

- Scrolling conversation view (user messages, assistant markdown, tool blocks).
- User messages rendered with background color.
- Tool executions rendered in `Box` with state-dependent background
  (pending/success/error).
- Tool output: syntax-highlighted code for read, diffs for edit, truncated
  bash output with expand.
- Footer: pwd, git branch, token stats, context %, model, thinking level.
- Editor at bottom with `> ` prompt.

### 5.5 TUI testing strategy

- **ANSI capture tests**: render components to a string buffer, compare output
  against golden ANSI snapshots (byte-exact).
- **Semantic cell tests**: parse ANSI output back into a cell grid, assert on
  cell content and style at specific coordinates.
- **Differential render tests**: feed two frames to renderer, verify minimal
  escape sequence output.
- **Layout tests**: render full UI at known widths, verify line counts and
  content positions.
- **Input tests**: feed key sequences, verify editor state and action dispatch.
- Tests run headless via `TestBuf` writer (no terminal needed).

### 5.6 Overlays

- Overlay stack for modals (model selector, settings, etc.).
- Overlays composite on top of base content lines.
- Focus tracking for input routing.

## Parallel Execution Model

## Workspace Pattern

- Root: `/Users/joel/Work/pz`
- Workspaces:
  - `/Users/joel/Work/pz-a`
  - `/Users/joel/Work/pz-b`
  - `/Users/joel/Work/pz-c`
  - etc.

## Commands

1. Create:
   - `jj workspace add ../pz-a`
2. Work independently:
   - each workspace owns a file set
3. Reconcile:
   - rebase/squash into integration change
4. Cleanup:
   - `jj workspace forget pz-a`

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

## M6

- TUI redesign complete: line-based scrolling, truecolor, component system.

## Execution Status (February 21, 2026)

- [x] Phase 0 complete
- [x] Phase 1 complete
- [x] Phase 2 complete
- [x] Phase 3 complete
- [x] Phase 4 complete
- [x] M1-M5 achieved
- [ ] Phase 5 in progress

Detailed user-visible parity tracking lives in `docs/parity.md`.
