# pz

A coding-agent harness rewritten from the ground up in Zig. Drop-in replacement for [pi](https://github.com/badlogic/pi-coding-agent) — same features, same config, single static binary.

## Why pz?

| | pi (TypeScript) | pz (Zig) |
|---|---|---|
| Binary size | ~10 MB + 589 MB node_modules | **1.7 MB** |
| Startup time | ~430 ms | **3 ms** |
| Memory at idle | ~153 MB | **1.4 MB** |
| Source lines | ~139k | **~29k** |
| Runtime deps | Node.js / Bun | **None** |
| Install | `bun install -g` | Copy one binary |

## Features

Full feature parity with pi, plus some extras:

- **Interactive TUI** — streaming responses, markdown rendering, syntax highlighting
- **Image rendering** — Kitty graphics protocol support in terminal
- **24 slash commands** — `/model`, `/fork`, `/export`, `/compact`, `/share`, `/tree`, and more
- **Autocomplete dropdown** — fuzzy-filtered command and file path completion
- **7 built-in tools** — `read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`
- **Session management** — persist, resume, fork, name, export, share as gist
- **OAuth + API key auth** — automatic token refresh, multi-provider support
- **Thinking modes** — adaptive and budget-capped extended thinking
- **Prompt caching** — automatic cache_control on system messages
- **Headless modes** — `--print`, `--json`, and `rpc` for scripting and integration
- **Zero-alloc hot path** — rendering and input handling avoid heap allocations
- **525 tests** — unit, integration, snapshot, and property tests

## Build

Requires [Zig](https://ziglang.org) 0.15+.

```
zig build -Doptimize=ReleaseFast
```

The binary lands in `zig-out/bin/pz`.

## Run

```
# Uses ~/.pi/agent/auth.json and settings.json automatically
pz

# Explicit provider and model
pz --provider anthropic --model claude-sonnet-4-20250514

# Headless
pz --print "explain this codebase"
echo '{"prompt":"hello"}' | pz --json
```

## Test

```
zig build test
```

## Config

pz reads pi's config files directly:

- `~/.pi/agent/auth.json` — OAuth / API key credentials
- `~/.pi/agent/settings.json` — model, provider, tools, thinking mode
- `AGENTS.md` / `CLAUDE.md` — system prompts (project and global)

## License

MIT
