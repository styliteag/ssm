---
name: ship
description: Package the current work into a correct SSM commit — pairing guards (schema↔migration), CHANGELOG entry, full verification, secrets hygiene, Conventional Commit message. Use whenever committing changes in this repo.
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
# Ecto schema change without migration? → STOP, write the migration first
git diff --staged --name-only | grep -qE 'phoenix/lib/ssm/.*/(host|user|user_key|authorization|activity_log)\.ex' && \
  { git diff --staged --name-only | grep -q 'priv/repo/migrations/' || echo 'GUARD FAIL: schema module staged without a migration'; }

# Version fields are release.sh territory → STOP if present
git diff --staged --name-only | grep -qx 'VERSION' && echo 'GUARD FAIL: VERSION is bumped only by release.sh'

# New IO.puts/IO.inspect in production code? → remove or justify
git diff --staged -- phoenix/lib | grep -E '^\+.*IO\.(puts|inspect)' && echo 'GUARD FAIL: new IO.puts/IO.inspect in lib'
```

Manual guards:
- Migration staged → it was verified against BOTH a fresh DB and a legacy snapshot
  (see AGENTS.md §6).
- `/api/v2` wire format untouched (field names, envelope, error codes) — changing it
  needs explicit user sign-off first.
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

Run the `verify` skill (equivalent to `just verify`): compile with warnings-as-errors,
`mix format --check-formatted`, ExUnit suite. All stages must pass.
CI will NOT catch failures — it has no test gate. A red gate means no commit.

## Step 5 — Commit

Message format: `<type>(<scope>): <imperative subject>` — types feat, fix, refactor,
docs, test, chore, perf, ci; scope like `(docker)`, `(elixir)`, `(diffs)` when it
sharpens the message. Body only when the "why" isn't obvious from the subject.
No co-author trailers.

```bash
git commit -m "fix(diffs): skip disabled hosts during scheduled sync"
```

- Never `--no-verify`. If the pre-commit hook blocks, fix the cause (or whitelist a
  genuine fixture with user approval) — never bypass.
- Do **not** push unless the user asked for a push. Pushing to main publishes.

## Step 6 — Report

State: what was committed (hash + subject), the CHANGELOG section used, and the verify
result per stage. If any guard was overridden at the user's request, say so explicitly.
