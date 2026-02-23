# Agent Rules

## Mission

Build `pz`: a Zig CLI harness with TUI. Do not optimize for compatibility with pi.

## Feature Fidelity (BLOCKING)

- Port all user-visible harness features faithfully.
- Redesign implementation for Zig, but keep capability parity.
- No feature drops, scope cuts, or behavior removals without explicit user approval.
- For each migrated feature, add or update a parity test/spec entry.
- If parity is unclear, stop and resolve the gap before continuing.

## Core Constraints

- Correctness over speed.
- No silent fallbacks.
- Root-cause fixes only.
- Keep names short and clear.
- Keep hot paths allocation-aware.

## Source Control

Use `jj`, not `git`.

- New change: `jj new`
- Describe change: `jj describe -m "<imperative message>"`
- Sync: `jj git fetch` / `jj git push`

## Parallel Work (Required)

For multi-agent work, use separate `jj` workspaces.

1. Create workspace per agent:
   - `jj workspace add ../pz-<agent>`
2. Assign file ownership per workspace.
3. Do not edit files owned by another workspace.
4. Reconcile by rebasing/squashing after each track stabilizes.
5. Clean up:
   - `jj workspace forget <name>`
   - Remove workspace directory.

## File Ownership Rule

If a file is touched by another active agent, stop and reassign before editing.

## Commit Rule

Only include files changed by the current agent/task. No broad staging.

## Testing Rule

Run relevant tests before and after each fix or feature.
Every bug fix must add or strengthen a test.
Use `ohsnap` snapshots for struct/multi-field outputs and serialized payload checks.
Use `std.testing.expectEqual` only for scalar primitives.

## Zig Rules

See `~/.agents/docs/zig.md`.

## Plan Rule

Track execution against `PLAN.md`.
When a plan item is complete, update status in commit message and notes.

## Release Rule

For release work, import and follow `.claude/skills/release/SKILL.md` in addition to this file.
Release prep must include a `CHANGELOG.md` entry for the new version before tagging.
