---
name: ship
description: Package the current work into a correct SSM commit — pairing guards (model↔migration, backend↔frontend types), CHANGELOG entry, full verification, secrets hygiene, Conventional Commit message. Use whenever committing changes in this repo.
---

A commit here is correct only if it satisfies the repo's hard rules (see AGENTS.md §3/§6).
This skill runs the guards in order; a failed guard stops the commit.

## Step 1 — Survey the change

```bash
git status --porcelain
git diff            # unstaged
git diff --staged   # staged
```

Stage exactly what belongs to this logical change. Split unrelated work into separate
commits (each with its own CHANGELOG entry).

## Step 2 — Pairing guards (STOP if any fails)

```bash
# Model change without migration? → STOP, run the db-migration skill first
git diff --staged --name-only | grep -q 'db/models.py' && \
  { git diff --staged --name-only | grep -q 'migrations/versions/' || echo 'GUARD FAIL: models.py staged without a migration'; }

# Version fields are release.sh territory → STOP if present
git diff --staged --name-only | grep -qx 'VERSION' && echo 'GUARD FAIL: VERSION is bumped only by release.sh'
git diff --staged -- backend/pyproject.toml | grep -q '^\+version = ' && echo 'GUARD FAIL: pyproject version is bumped only by release.sh'

# New console/print in production code? → remove or justify
git diff --staged -- backend/src frontend/src | grep -E '^\+.*(console\.(log|warn|error)|print\()' | grep -v test && echo 'GUARD FAIL: new console/print in src'
```

Manual guards:
- Backend request/response model changed → `frontend/src/types/index.ts` and the
  affected service must be in this commit (or explicitly deferred with the user's OK).
- New `ErrorCode` → frontend catch-paths that should branch on it are updated.
- No secret-shaped strings in the diff. Test fixtures needing one go into
  `.secrets-whitelist` as a `VALUE:` entry — and that edit requires user approval.

## Step 3 — CHANGELOG

`CHANGELOG.md` must gain an entry under `[Unreleased]` in the right Keep-a-Changelog
section (`Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security`):

- Written for a user/operator: what changed and why it matters. Not commit-message
  phrasing, not implementation trivia.
- Stage it with the code: this is a same-commit rule, no follow-ups.
- Exception: pure `chore: bump version` commits made by `release.sh` itself.

## Step 4 — Verify

Run the `verify` skill (equivalent to `just verify`): backend ruff + mypy --strict +
bandit + pytest, frontend eslint (0 warnings) + tsc. All six gates must pass.
CI will NOT catch failures — it has no test gate. A red gate means no commit.

## Step 5 — Commit

Message format: `<type>(<scope>): <imperative subject>` — types feat, fix, refactor,
docs, test, chore, perf, ci; scope like `(docker)`, `(migrations)`, `(dashboard)` when
it sharpens the message. Body only when the "why" isn't obvious from the subject.
No co-author trailers.

```bash
git commit -m "fix(diffs): skip disabled hosts during scheduled sync"
```

- Never `--no-verify`. If the pre-commit hook blocks, fix the cause (or whitelist a
  genuine fixture with user approval) — never bypass.
- Do **not** push unless the user asked for a push. Pushing to main publishes.

## Step 6 — Report

State: what was committed (hash + subject), the CHANGELOG section used, and the verify
result per gate. If any guard was overridden at the user's request, say so explicitly.
