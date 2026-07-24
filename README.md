# pz

A security-first coding harness rewritten from the ground up in Zig for enterprise environments. `pz` is not a generic extensible agent platform, for now: the goal is peace of mind through built-in security, policy, auditability, and a single static binary.

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

### Harness

- **Interactive TUI** — streaming responses, markdown rendering, syntax highlighting
- **Image rendering** — Kitty graphics protocol support in terminal
- **24 slash commands** — `/model`, `/fork`, `/export`, `/compact`, `/share`, `/tree`, and more
- **Autocomplete dropdown** — fuzzy-filtered command and file path completion
- **9 built-in tools** — `read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`, `ask`, `web`
- **Skills** — discoverable `/skillname` slash commands with frontmatter, registry, and policy gating
- **Session management** — persist, resume, fork, name, export, share as gist
- **Provider command adapters** — route model calls through explicit approved CLI adapters
- **Thinking modes** — adaptive and budget-capped extended thinking
- **Prompt caching** — automatic cache_control on system messages
- **Headless modes** — `--print`, `--json`, and `rpc` for scripting and integration
- **Agent tool** — spawn subagents with dedicated RPC fd, progress streaming, process group isolation
- **Zero-alloc hot path** — rendering and input handling avoid heap allocations

### Security

- **Signed policy bundles** — Ed25519-verified policy with lock mode, generation rollback resistance, and expiry
- **Tool sandbox** — process group isolation, env scrubbing, TERM→KILL escalation
- **Egress policy** — deny-by-default endpoint allowlists, bounded deadlines, policy-bound proxy
- **TOCTOU guards** — fd-pinned tool I/O with `readlinkat`/`O_NOFOLLOW`, hardlink rejection, root confinement
- **Symlink escape prevention** — component-by-component path walk for tool paths and context files
- **Shell tokenizer** — parse `bash -c`, quoting, command substitution for policy-driven command denial
- **Prompt injection boundaries** — untrusted content wrapped with provenance markers, context budgets
- **DNS rebinding protection** — private-range blocking on web tool and redirect hops
- **Secret zeroization** — Ed25519 seed/keypair wiped after use
- **Absolute-path commands** — `/share`, `/copy`, editor, paste use absolute paths, not PATH resolution

### Audit

- **Structured audit log** — typed events with severity, outcome, HMAC-SHA256 chained integrity
- **Syslog shipping** — RFC 5424 UDP/TCP with TLS hooks, hostname resolution, reconnect backoff
- **Durable spool** — file-backed audit spool with ordered resend on collector reconnect
- **Keyed redaction** — HMAC-based per-session pseudonyms, non-correlatable across deployments
- **Privileged action audit** — export, share, copy, model change, subagent, editor launch tracked
- **Pipeline sanitization** — ANSI/control stripping and secret redaction for `--print`/`--json` output

### Enterprise

- **Canonical `.pz/` layout** — settings, auth, policy, sessions, audit under one root
- **Signed self-update** — Ed25519 manifest verification, key ring with rollback/downgrade detection, crash-safe install
- **Context-bound approvals** — tool kind, cwd, repo root, policy hash, session lifetime binding
- **LRU approval cache** — bounded eviction for context-bound approvals
- **Fail-closed policy** — unknown keys rejected, unsigned policies rejected in lock mode
- **Secure local storage** — 0700/0600 perms, atomic writes (temp+fsync+rename), O_NOFOLLOW confinement
- **Event loop** — kqueue (macOS) event loop core with provider and tool I/O migration

### Testing

- **1300+ tests** — unit, integration, snapshot (ohsnap), and property (zcheck) tests
- **PTY harness** — real-process TUI tests with ANSI AST parsing
- **Mock infrastructure** — provider, syslog, HTTP, cancel, time mocks
- **Allocator regression** — test-allocator proofs for UAF and leak safety

## Build

Requires [Zig](https://ziglang.org) 0.15+.

```
zig build -Doptimize=ReleaseFast
```

The binary lands in `zig-out/bin/pz`.

Release builds require `-Dgit-hash=<hash>` and embed `CHANGELOG.md`. Debug builds use VCS.

## Run

```
# Canonical state lives under ~/.pz/ and ./.pz/
pz

# Default approved provider command adapter
pz --provider codex --model gpt-5.6-sol

# Explicit approved provider command adapter override
PZ_PROVIDER_CMD='pz-provider-codex' pz --provider codex --model gpt-5.6-sol

# Headless
pz --print "explain this codebase"
echo '{"prompt":"hello"}' | pz --json
```

## Test

```
zig build test
```

## Changelog

- `CHANGELOG.md` for release-by-release notes
- `pz --changelog` or `/changelog` in TUI for in-app change visibility

## Config

Canonical `pz` state lives under `.pz/`:

- `~/.pz/settings.json` — global defaults
- `./.pz/settings.json` — project-local overrides
- `~/.pz/auth.json` — legacy auth file; direct provider login is disabled in this fork
- `~/.pz/state.json` — local machine state
- `~/.pz/sessions/` and `./.pz/sessions/` — persisted sessions
- `~/.pz/policy.json` and `./.pz/policy.json` — authoritative signed policy bundles
- `~/.pz/skills/` and `./.pz/skills/` — skill definitions
- `AGENTS.md` — policy-controlled context files

## License

MIT
