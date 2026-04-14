---
name: release
description: Cut a new SSM release via ./release.sh. Accepts patch|minor|major as $ARGUMENTS. Validates clean tree, bumps VERSION + backend/Cargo.toml, commits, tags, pushes (triggers GitHub Actions build).
disable-model-invocation: true
---

Release is destructive-ish (pushes tag, triggers CI publish). User must invoke explicitly.

## Steps

1. Parse `$ARGUMENTS` → one of `patch` | `minor` | `major`. If missing/invalid, ask user.
2. Confirm with user before running (show bump type and current version from `VERSION` file).
3. Verify CHANGELOG.md has entries under `[Unreleased]`. If empty, stop and ask user to populate.
4. Run `./release.sh <bump>` from repo root.
5. Report new version + tag + remote URL so user can monitor the GitHub Actions build.

## Notes

- Do NOT bypass pre-commit hooks.
- Script pushes to `origin` and tag triggers multi-arch Docker build.
- If working tree dirty, script aborts — tell user to commit or stash first.
