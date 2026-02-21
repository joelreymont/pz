# pz

Minimal re-implementation of [pi](https://github.com/nicholasgasior/pi) coding-agent harness in Zig.

Single binary, no runtime dependencies. Interactive TUI, headless print/JSON modes, and an RPC interface.

## Build

```
zig build
```

## Run

```
zig build run -- --provider google --model gemini-2.5-pro
```

## Test

```
zig build test
```

## Features

- Interactive TUI with streaming responses
- Headless print, JSON, and RPC modes
- Tools: `read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`
- Session persistence and resume
- Auto-import of pi settings from `~/.pi/agent/settings.json`

## License

MIT
