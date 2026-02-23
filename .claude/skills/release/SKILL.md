---
name: release
description: >
  Release pz with GitHub Actions. Bumps version in build.zig.zon, tags, pushes,
  and monitors CI. Use when user says "release", "bump version", "bump patch",
  "bump minor", "bump major", "cut a release", or "publish".
user_invocable: true
---

# Release Skill for pz

## Trigger Phrases

- `/release` — auto-detect bump level from commits
- `/release patch` or "bump patch" — patch bump (0.1.0 → 0.1.1)
- `/release minor` or "bump minor" — minor bump (0.1.0 → 0.2.0)
- `/release major` or "bump major" — major bump (0.1.0 → 1.0.0)

## Procedure

### 1. Determine current version and bump level

Read `build.zig.zon` and extract current `.version` field.

Parse the argument (patch/minor/major). If no argument given, inspect commits since last tag to decide:
- Any breaking change or "breaking" in message → major
- New feature, "add", "feat" → minor
- Everything else → patch

### 2. Compute new version

```
patch: X.Y.Z → X.Y.(Z+1)
minor: X.Y.Z → X.(Y+1).0
major: X.Y.Z → (X+1).0.0
```

### 3. Run tests

```bash
zig build test
```

If tests fail, stop and report.

### 4. Cross-compile check (don't overwrite native binary)

```bash
zig build check -Dtarget=x86_64-linux
zig build check -Dtarget=aarch64-linux
zig build check -Dtarget=aarch64-macos
zig build check -Dtarget=x86_64-macos
```

### 5. Update version in build.zig.zon

Edit `.version = "X.Y.Z"` to new version. Use the Edit tool.

### 6. Commit and push

```bash
jj describe -m "Bump version to X.Y.Z"
jj git push
```

### 7. Tag and push tag

jj bookmarks conflict with git tags when they share names. Use git directly for tagging:

```bash
git tag vX.Y.Z $(jj log -r @ --no-graph -T 'commit_id' | head -c 40)
git push origin vX.Y.Z
```

### 8. Monitor release CI

```bash
gh run list --limit 1
gh run watch <run_id>
```

Wait for all 4 builds (x86_64-linux, aarch64-linux, x86_64-macos, aarch64-macos) and the release job to succeed.

### 9. Verify release

```bash
gh release view vX.Y.Z
```

Confirm 4 artifacts are attached:
- pz-x86_64-linux.tar.gz
- pz-aarch64-linux.tar.gz
- pz-x86_64-macos.tar.gz
- pz-aarch64-macos.tar.gz

Report the release URL to the user.

### 10. If CI fails

```bash
# Delete the tag
git push origin :refs/tags/vX.Y.Z
git tag -d vX.Y.Z
```

Fix the issue, then restart from step 3.

## Important

- NEVER use `zig build -Dtarget=...` for cross-compile checks — it overwrites the native binary. Use `zig build check -Dtarget=...` instead.
- The release workflow (`.github/workflows/release.yml`) triggers on `v*` tags and builds ReleaseFast binaries for all 4 targets.
- Version source of truth is `build.zig.zon` `.version` field, baked into the binary via build options.
