# Changelog

All notable changes to this project will be documented in this file.

## [0.1.8] - 2026-02-23

### Changed
- Compaction status is now shown in the border status line as a transient `compaction` indicator with spinner/blink treatment; the ambiguous footer `(auto)` badge was removed.
- Manual `/compact` now drives the same compaction indicator path as auto-compaction.

### Fixed
- Markdown tables now render with full Pi-style enclosure (`┌┬┐`, `├┼┤`, `└┴┘`) and stable per-column padding so column boundaries stay aligned.
- Markdown table height accounting now includes border/separator rows, preventing scroll/tail math drift around table blocks.
- CI push failures caused by unformatted table-render changes were eliminated by formatting and validating the full CI command set (`fmt/build/check/test/perf`) before release.

### Tests
- Added transcript and e2e fixture regressions verifying table enclosure glyphs, column alignment, and explicit space padding around cell contents.
- Added harness/panels regressions for compaction indicator lifecycle and placement.

## [0.1.7] - 2026-02-23

### Changed
- Footer status line now prioritizes token/accounting data and shows input/output tokens as `R... W...` (matching Pi-style read/write labels).
- Footer no longer shows provider prefix or input-mode/queue counters (`(anthropic)`, `steering`, `qN`) to reduce clutter.

### Fixed
- Markdown table rendering in transcript view now preserves table row structure instead of wrapping pipe rows into broken layouts.
- Markdown scroll-state handling now advances table/header state correctly for skipped rows, preventing bold/header styling bleed during scrollback.
- Tool call/result transcript blocks now recolor post-factum on result (pending -> success/error) and keep grouped tool rows visually contiguous.
- Footer right-side model rendering now respects left-side stats width and no longer overwrites token/cost counters on narrow terminals.

### Tests
- Added transcript regressions for markdown-aware wrapping, table-row preservation, and skipped-row table-state correctness.
- Added footer regressions validating `R/W` token display and absence of mode/queue text.

## [0.1.6] - 2026-02-23

### Changed
- Updater/version HTTP client now initializes proxy settings from standard env vars (`http_proxy`, `https_proxy`, `all_proxy` and uppercase variants).

### Fixed
- Upgrade HTTP errors now extract meaningful HTML message text (`title`/`h1`/`h2`/`p`) instead of printing truncated markup.
- HTTP 400 upgrade failures now report a targeted hint for proxy/header rewriting scenarios.

### Tests
- Added updater regression covering HTML error-message extraction for 400 responses.

## [0.1.5] - 2026-02-23

### Fixed
- TUI now decodes SS3 arrow sequences (`ESC O A/B`) so Up/Down navigation works in command preview and overlays on terminals using application-cursor mode.
- Slash-command transcript writes now sanitize invalid UTF-8 instead of crashing, preventing `/upgrade` and other command outputs from aborting the UI on non-UTF-8 bytes.

### Tests
- Added input parser regressions for SS3 Up/Down arrow decoding.
- Added runtime regressions for lossy UTF-8 sanitization and safe transcript insertion of invalid command output.

## [0.1.4] - 2026-02-23

### Added
- Shared user-facing error reporter for CLI, TUI, and RPC command paths with actionable `reason` and `next` guidance.

### Changed
- `--upgrade`/`/upgrade` now return structured outcomes and detailed diagnostics (operation, transport/http cause, response snippet, and recovery guidance) instead of opaque error codes.
- Resume-session overlay flow is now centralized so both startup and interactive `/resume` paths use the same picker behavior.

### Fixed
- Command and RPC failures no longer surface raw internal error names by default in user-facing output.
- Improved tool-value validation hint to show accepted tool names directly in the message.

### Tests
- Added update diagnostics tests for HTTP-failure message formatting and response-sanitization behavior.
- Added session-restore UX tests covering resume overlay listing, ordering, and up/down arrow wrap navigation.
- Added explicit runtime parity test for `-r` (resume latest session) behavior.

## [0.1.3] - 2026-02-23

### Changed
- Native provider auth now accepts environment credentials, with `ANTHROPIC_OAUTH_TOKEN` taking precedence over `ANTHROPIC_API_KEY`.

### Fixed
- Resolved startup failure on machines configured only with `ANTHROPIC_API_KEY` where native provider init previously fell back to `provider_cmd` error.
- Improved missing-provider diagnostic text to direct users to Anthropic auth env vars, `/login anthropic <key>`, or `--provider-cmd`.
- Removed a non-deterministic runtime test skip guard allocation path that could leak under `zig build test`.

### Tests
- Added auth unit tests for env credential precedence and file auth parsing/missing-file behavior.
- Updated runtime no-provider test expectation for the new provider-unavailable diagnostic.

## [0.1.2] - 2026-02-23

### Added
- Self-upgrade support via `--upgrade`, `--self-upgrade`, `/upgrade`, and RPC `upgrade`.
- Release update notifications in TUI with direct upgrade guidance.
- Background-job spinner animation in the footer while jobs are running.
- Footer status now consistently shows project path and active branch.
- New built-in `ask` tool for structured interactive question flows in TUI.
- Input mode toggle (`Alt+Down`) for `steering` and `queue`, with footer status (`mode ... qN`).
- Queued-message picker (`Alt+Up`) to navigate queued prompts and restore one into the editor for editing.
- Persistent background job journal with startup recovery and stale-job cleanup.
- Parity spec document at `docs/parity.md` covering command, footer, bg, and ask-tool behavior.

### Changed
- Release artifacts remain focused on 3 targets: `x86_64-linux`, `aarch64-linux`, `aarch64-macos`.
- Command preview list now includes `upgrade`.
- Top-level runtime execution now uses a labeled `switch` state machine (`init_provider -> init_store -> dispatch -> done`).
- Tool schema generation supports per-tool schema overrides (used by `ask` for nested question payloads).

### Fixed
- Version update notice no longer depends on a one-time startup poll; it appears when async check completes.
- Branch detection in JJ working-copy states now falls back correctly (including parent bookmark lookup).
- Long project paths no longer hide the branch in narrow footer layouts.

### Tests
- Added updater tests for archive extraction, missing binary edge case, and atomic install replacement.
- Added parser/CLI tests for upgrade flags and command dispatch.
- Added footer tests for branch visibility with long paths and JJ bookmark parsing behavior.
- Added input queue tests for `Alt+Down` mode switching, queue overlay selection/edit restore, and queue footer state.
- Added `ask` tool tests for hook wiring, empty-question validation, and hook-failure surfaces.
- Added bg journal tests for replay, cleanup, malformed lines, and stale-entry recovery.
- Added parity harness snapshot coverage for slash command + bg lifecycle flow.
- CI now enforces parser performance budget with an explicit ReleaseFast perf gate.

## [0.1.1] - 2026-02-23

### Changed
- Removed `x86_64-macos` from release builds and artifacts.
