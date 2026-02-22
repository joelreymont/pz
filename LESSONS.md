# Lessons Learned

Hard-won patterns and anti-patterns from building pz. **Update this file at the end of every session** with new discoveries.

---

## Session Notes (2026-02-22)

### Worked Well
- Running pi and pz in parallel tmux sessions (100x50) with `tmux capture-pane -p -S -500` gives exact terminal output for side-by-side parity comparison. Captures must happen while TUI is running since pz uses alternate screen buffer.
- Formatting tool calls as `$ cmd args` (parsing JSON args to extract command/path) matches pi's display and is much more readable than raw `[tool name#id]` format.
- Collapsing long tool output with `... (N earlier lines, ctrl+o to expand)` keeps the transcript compact without losing information.
- Suppressing usage/stop protocol events from transcript (handling them only in panels/status bar) eliminates visual noise that pi doesn't show.
- Using `pushAnsi()` with span-based coloring for tool results preserves ANSI colors from tool output (e.g., colored grep results) while keeping the frame-buffer rendering clean.
- Adding `eofReader()` test helper (returns 0 bytes = EOF) replaced all `null` input readers in runtime tests, preventing them from blocking on real stdin in non-TTY mode.

### Did Not Work
- Passing `null` for input reader in runtime tests caused real stdin reads in non-TTY mode, hanging tests indefinitely. Always use an explicit EOF reader.
- Early `return` after processing `-p` prompt caused pz to exit immediately after the first response instead of staying in TUI mode like pi. The prompt path must fall through to the input loop.
- Using `frame.Color.eql` directly on `vscreen.Color` types in fixture tests caused type mismatch. Must use VScreen's own `expectFg`/`expectBg` methods.
- Variable name `count` in `pushToolResult` shadowed `Transcript.count()` method. Zig treats method names as field access, so local variables must not shadow struct method names.
- Zig 0.15's `std.Io.AnyReader` (DeprecatedReader) is a flat struct with `context: *const anyopaque` and `readFn`, not a vtable-based interface. Constructing it requires `.{ .context = undefined, .readFn = &S.read }`.

## Architecture & Design

### TUI parity approach
Compare against pi by running both with identical prompts and capturing terminal output. Track specific gaps (status bar fields, startup sections, transcript formatting) as discrete tasks. Fix the most visually impactful differences first.

### Transcript block kinds control visibility
The `Kind` enum (text, thinking, tool, err, meta) determines per-block filtering via `show_tools` and `show_thinking` flags. Tool display and thinking display are independent toggles. Thinking defaults to visible (matching pi), toggled with ctrl+t.

### Status bar accumulates across turns
Usage stats (in/out tokens, cache R/W, cost) come from provider usage events and accumulate in `Panels.usage`. The status bar renders these on each frame.

### Cost calculation uses integer micents
Cost is tracked in micents (1/100000 of a dollar) to avoid floating point. Rates are stored in cents/MTok. Formula: `tokens * rate_cents / 1000`. Model tier detected by substring match ("opus", "haiku", default sonnet). Displayed as `$N.NNN`.

### Prompt caching needs minimum token count
Anthropic requires ~1024 tokens in a cached block before it actually caches. Short system prompts won't trigger caching. `cache_control: {"type": "ephemeral"}` is set on the last system text block. R/W tokens show in status bar when >0.

### OAuth = subscription
Auth type from `~/.pi/agent/auth.json` determines subscription status. OAuth users get `(sub)` indicator in status bar. API key users don't. Detected via `Client.isSub()` and passed through `runTui()` as bool.

### Skills discovery is simple glob
`~/.claude/skills/*/SKILL.md` — iterate dirs, check file exists, sort for stable display. Shown in `[Skills]` startup section matching pi.

### jj bookmark for branch display
Pi shows git branch in footer, but jj repos have detached HEAD. Use `jj log --no-graph -r @ -T bookmarks` to get the jj bookmark name. Strip trailing `*` (dirty indicator). Fall back to git branch, then `detached`.

### TurnCtx eliminates parameter sprawl
`runTuiTurn` had 12+ params passed from 7 call sites. Replaced with `TurnCtx` struct holding stable loop state (alloc, provider, store, tools_rt ptr, mode, max_turns). Per-turn variables (sid, prompt, model, opts) passed via `TurnOpts`. Store `*tools.builtin.Runtime` (pointer) not `tools.Registry` (value) so `/tools` changes are visible.

### Overlay composites on frame buffer
Model selector overlay renders directly onto the frame buffer after normal TUI content, before `rnd.render()`. Key interception happens before `ui.onKey()` — when overlay is open, up/down/enter/esc are handled by overlay, not editor. Box-drawing chars (┌┐└┘│─) make clean borders.

### ESC cancellation needs raw mode + dedicated thread
Detecting ESC during streaming requires a dedicated InputWatcher thread (mirrors pi's CancellableLoader + AbortController pattern). The thread uses `poll()` with 100ms timeout + `read()` on stdin, setting an atomic bool when ESC (0x1b) is received. Critical: raw mode (`enableRaw`) MUST be set before starting the thread — in canonical mode, `poll()` POLLIN only fires on complete lines, so bare ESC never triggers it. The `enableRaw` call was moved before the `-p` prompt path for this reason. Non-blocking approaches (`fcntl O_NONBLOCK`, inline `pollCancel` in push callback) failed on macOS due to Zig's `read()` wrapper returning `WouldBlock` even when `std.c.read()` returns 0.
