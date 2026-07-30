# SSM — Operating Manual for Coding Agents

`CLAUDE.md` is a symlink to this file. This is not a project description — it is the
operating manual. Follow it literally. When this file and the code disagree, the code
wins; fix this file in the same commit and say so.

**Product**: Secure SSH Manager — a web app that manages `authorized_keys` files across
many hosts. Elixir/Phoenix LiveView UI + a wire-compatible `/api/v2` JSON API, SQLite
via `ecto_sqlite3`, htpasswd auth (session cookies for the UI, HS256 JWT for the API).

**History you must know**: SSM was a Rust/Actix/Diesel app, rewritten in
Python/FastAPI + React, then rewritten again in Elixir/Phoenix. The Python and React
stacks (`backend/`, `frontend/`) and the old nginx+uvicorn image (`docker/app/`) were
**deleted** — everything lives in `phoenix/` now. Ghosts of both previous stacks
remain in old docs, the CHANGELOG, and `.secrets-whitelist`. There is no `Cargo.toml`,
no FastAPI, no npm, no Alembic. If you find a reference to any of those, it is stale —
do not act on it (see mistake #9). The database schema, however, still carries its
Diesel/Alembic ancestry — inherited production DBs are adopted in place, never
recreated.

---

## 1. Orientation

| Path | What lives there |
|------|------------------|
| `phoenix/lib/ssm/` | Domain contexts: `hosts.ex`, `users.ex` (+ `user_key`, `key_parser`, `bulk_ops`), `authorizations.ex`, `diffs.ex` (+ `status_cache`), `activity.ex`, `auth/` (htpasswd, JWT token), `release.ex` (prod migrate) |
| `phoenix/lib/ssm/ssh/` | `client.ex` (behaviour), `erlang_client.ex` (prod), `mock_client.ex` (tests), `safety.ex` (readonly markers), `script_runner.ex`, `cache.ex` |
| `phoenix/lib/ssm_web/live/` | One LiveView per page: dashboard, hosts, users, keys, authorizations, diff, activities, login |
| `phoenix/lib/ssm_web/api/` | `/api/v2` plumbing: `auth_plug.ex` (bearer JWT), `envelope.ex`, `errors.ex` (stable error codes), `params.ex` |
| `phoenix/lib/ssm_web/controllers/api/` | One controller per API domain: auth, hosts, users, keys, authorizations, diffs, activity_log, info |
| `phoenix/priv/repo/migrations/` | Ecto migrations. `20260101000000_baseline_schema.exs` **adopts** Diesel-/Alembic-era DBs in place (fills gaps, stamps) — read it before touching the schema. |
| `phoenix/test/` | ExUnit: context tests under `ssm/`, LiveView + API contract tests under `ssm_web/`, fixtures in `support/` |
| `phoenix/compose.yml` | Dev environment — docker-only toolchain, no local Elixir. Mounts `phoenix/keys/` read-only. |
| `phoenix/Dockerfile` | Production `mix release` image (build context = repo root; serves :80, migrates on start) |
| `docker/` | Production deployment: `compose.yml` + `data/` volumes (db/config/keys/logs — same layout and data as the previous python image) |
| `justfile` | The command interface. Prefer `just <target>` over raw commands. |

**Data model** (SQLite, table names are singular — Diesel parity): `host`, `user`,
`user_key`, `authorization`, `activity_log`. `authorization` links user↔host with a
remote `login`. `host.disabled` blocks all SSH operations.

**Request paths**: UI — session cookie (htpasswd login) → LiveView. API — Bearer JWT
(`AuthPlug`) → controller → envelope `{success, data, error{code,message,details},
meta}`. SSH goes through the `Ssm.Ssh.Client` behaviour (mock in tests), never
`:ssh` directly in web code. Errors are tagged tuples, not exceptions.

## 2. Commands

```bash
just dev                 # dev server on :4000 (docker compose, live reload)
just verify              # THE quality gate: compile --warnings-as-errors + format --check-formatted + ExUnit
just test <path>         # subset: just test test/ssm_web/api/
just mix <task>          # any mix task inside the dev container
just up / down / logs    # production stack (docker/compose.yml)
just docker-run          # prod image on :8080 with scratch data under /tmp
```

CI has **no test/lint gate** — only secret scanning and Trivy. `just verify` on your
machine is the only quality gate that exists. Treat it as mandatory, not advisory.

## 3. Non-negotiable rules

1. **Every schema change ships an Ecto migration** in the same commit as the schema
   change, and every migration must work on BOTH a fresh DB and an inherited
   Diesel-/Alembic-era DB adopted by the baseline migration. Never hand-written DDL
   against a prod-shape DB.
2. **Every commit updates `CHANGELOG.md`** under `[Unreleased]`, Keep-a-Changelog
   sections, user-visible wording. (Releases 1.1.4–1.1.7 shipped empty because commits
   skipped this; it was backfilled by hand. Don't repeat that.)
3. **The `/api/v2` wire format is frozen**: envelope shape, field names, and the
   stable error codes are a compatibility contract with deployed API clients (and the
   old python stack's tokens). Changing any of it is a breaking change — ask first.
4. **Every SSH-touching code path checks `host.disabled` first** and honors the remote
   readonly markers (`.ssh/system_readonly`, `.ssh/user_readonly`).
5. **`just verify` passes before you call anything done.**
6. **Never `git commit --no-verify`.** Never weaken `.githooks/pre-commit` or
   `.secrets-whitelist` without explicit user approval.
7. **Versions are bumped only by `./release.sh`** (updates `VERSION`, rotates the
   CHANGELOG, tags, pushes; `mix.exs` reads `../VERSION`). Never edit version fields
   by hand.
8. **Work lands on `main`** in Conventional-Commit style: `<type>(<scope>): imperative
   subject` — types: feat, fix, refactor, docs, test, chore, perf, ci. No co-author
   trailers.
9. **No new dependency** in `phoenix/mix.exs` without asking. The JWT layer runs on
   OTP `:crypto` deliberately — no jose/joken.
10. **No `IO.puts`/`IO.inspect` in production code paths.** Use `Logger`.

## 4. Conventions

- Contexts own all Repo access; LiveViews and controllers never call `Ssm.Repo`
  directly. Copy the shape of an existing context (`hosts.ex`) before inventing one.
- Failures are tagged tuples (`{:error, :host_not_found}`, `{:error,
  {:ssh_connect_failed, msg}}`) that map to stable API error codes in
  `ssm_web/api/errors.ex`. New failure modes get a new tagged atom + mapping there.
- New/changed API endpoint → contract test under `phoenix/test/ssm_web/api/`
  asserting `status`, `body["success"]`, envelope `data`/`meta`, and `error.code` —
  plus one unauthenticated 401 `AUTH_REQUIRED` test. The suite mirrors the old pytest
  contract suite's assertions; keep that discipline.
- SSH in tests: `MockClient` only. There is no real-network test in the suite.
- LiveView pages follow the existing house style: sortable tables via
  `ssm_web/table_sort.ex`, list/card toggles, theme-aware semantic classes (four
  themes × light/dark — check both when touching UI).
- `mix format` is enforced by `just verify`; run `just format` before committing.
- Runtime dependency changed (with user approval, rule #9) → `just notices`
  regenerates `THIRD-PARTY-LICENSES.md` + `sbom.cdx.json` in the same commit.
- Prefer extending an existing pattern over introducing a new abstraction. One
  precedent file is worth more than a better idea.
- Document what **is**, not what is planned. When you fix a stale doc statement, note
  it in the commit body.

## 5. Named mistakes — what you will get wrong here, and the rule that prevents it

1. **The Schema Drift.** Changing an Ecto schema module and calling it done. *Rule: no
   schema change without a migration in `phoenix/priv/repo/migrations/` in the same
   commit, verified against both fresh and legacy-adopted DBs.*
2. **The Silent Release.** Committing without a CHANGELOG entry; the release ships
   empty notes. *Rule: `CHANGELOG.md` is staged in every commit (rule #2).*
3. **The Envelope Break.** Returning a bare map or a free-form error string from an
   API controller. Clients switch on `error.code`, not messages. *Rule: envelope +
   stable codes via `ssm_web/api/envelope.ex` / `errors.ex` only.*
4. **The Legacy DB Amnesia.** Writing a migration that works on a fresh DB but crashes
   on an inherited Diesel-/Alembic-era DB. The baseline migration adopts those in
   place; later migrations must expect either origin. *Rule: test schema changes
   against a copy of a legacy snapshot (`./ssm.db`), not just a fresh dev DB.*
5. **The Real SSH Call.** Using `:ssh` in web code or writing a test that opens a
   connection. *Rule: web code speaks to the `Ssm.Ssh.Client` behaviour; tests use
   `MockClient`. Never test against real hosts — this repo's data references
   production machines.*
6. **The Disabled Host Bypass.** Adding an SSH operation that skips the `disabled`
   check or readonly markers. *Rule: every new SSH path refuses disabled hosts and
   readonly-marked targets — with a test proving it.*
7. **The Version Hand-Bump.** Editing `VERSION` or tagging manually. *Rule: only
   `./release.sh` (interactive — it prompts; never run it headless or unasked).*
8. **The Trusting-CI Fallacy.** Seeing green GitHub checks and assuming tests passed.
   CI runs security scans only. *Rule: quality is proven exclusively by local
   `just verify`.*
9. **The Ghost Stack.** Acting on stale artifacts of the Rust or Python/React eras:
   `Cargo.toml` or `pyproject.toml` references, Alembic commands, npm scripts,
   `backend/`/`frontend/` paths, v1 API shapes, `config.toml`. *Rule: the app is
   Elixir under `phoenix/`, the API is `/api/v2`, config is env vars
   (`config/runtime.exs`). Stale references get fixed or ignored, never obeyed.*
10. **The Whitelist Symlink Gap.** Assuming this file is exempt from the secrets hook.
    `.secrets-whitelist` lists `CLAUDE.md`, but what gets staged is `AGENTS.md` — which
    is **not** whitelisted. *Rule: keep secret-shaped strings out of this file; reuse
    the exact example values already present in the repo when documenting.*
11. **The Local-Toolchain Assumption.** Running `mix` on the host and hitting version
    drift (or missing Elixir entirely). *Rule: the toolchain is docker-only — always
    `just mix <task>` / `just test` / `just verify`.*

## 6. Quality bar per deliverable — checkable, not adjectives

### Any commit
- [ ] `just verify` exits 0 (compile with warnings-as-errors, format check, ExUnit).
- [ ] `CHANGELOG.md` staged with an entry under `[Unreleased]` in the correct section,
      written as what a user/operator would notice.
- [ ] Message matches `<type>(<scope>): <imperative subject>`; no co-author trailer.
- [ ] `git diff --staged` contains no new `IO.puts`/`IO.inspect`, no secrets, no
      commented-out code blocks, no version-field edits.
- [ ] If a schema module is in the diff, a `priv/repo/migrations/` file is too.

### API endpoint / feature
- [ ] Route behind `AuthPlug` (only `auth/login`, `auth/refresh`, and `/api/health`
      are public).
- [ ] Envelope on success incl. `meta.total` for lists; failures map to stable
      `error.code` values.
- [ ] Contract tests: 401 unauthenticated, happy path incl. envelope shape, each
      domain error (404/409) by `error.code`.
- [ ] SSH involved → disabled-host and readonly paths tested with `MockClient`.

### Database migration
- [ ] Works on a fresh DB AND on a legacy snapshot adopted by the baseline (copy
      `./ssm.db` over `phoenix/ssm_dev.db`, boot, verify).
- [ ] `down` works, or a comment explains why not.
- [ ] SQLite-compatible operations only; schema change + migration + CHANGELOG in one
      commit.

### UI change
- [ ] Follows an existing LiveView's patterns; checked in dark and light (and ideally
      across themes).
- [ ] No new dependency; formatted.

### Release (only when the user explicitly asks)
- [ ] Working tree clean; `[Unreleased]` non-empty; run `./release.sh patch|minor|major`
      interactively; report the new tag and the Actions run URL.

### Docs
- [ ] Describes current behavior (verified against code this session), not plans.
- [ ] Stale statements you found are fixed in the same commit and mentioned in its body.

## 7. When uncertain — exact escalation rules

**Stop and ask the user before:**
1. Any migration that drops or renames a table/column, or any operation on a database
   file that is not a throwaway test DB (includes `ssm.db` / `ssm_dev.db` files in the
   working tree — they contain real host data).
2. Changing the wire format of an existing endpoint (renaming/removing fields, changing
   types, changing an error code) — deployed clients depend on it.
3. Touching auth semantics: JWT claims/TTLs, htpasswd handling, session cookie config,
   which routes are public.
4. Adding a dependency to `phoenix/mix.exs`.
5. `./release.sh`, `git push`, tagging, or anything that triggers CI publishing.
6. `--no-verify`, editing `.githooks/`, or editing `.secrets-whitelist`.
7. Deleting or rewriting files you did not create this session (beyond the edit asked
   for).

**Proceed without asking:** anything reversible in the working tree that follows from
the request — code, tests, migrations (kept uncommitted until checks pass), refactors
within the conventions above, doc fixes.

**Conflict resolution:**
- Docs vs code → code wins; fix the doc in the same commit.
- Knowledge-graph output vs file contents → files win (the graph can lag).
- This manual vs an explicit user instruction → the user wins; note the deviation.

**Failure handling:**
- A verify gate fails on something you didn't touch → retry once; if it persists,
  report it verbatim and stop. Do not "fix" unrelated tests to get green.
- Two distinct fix attempts for the same failure both fail → stop, present both
  attempts and the error output, ask.
- Missing secret/credential/env value → ask; never invent or hardcode one.

## 8. Reference

**API** (all under `/api/v2`, plural resources): `hosts`, `users`, `keys`,
`authorizations`, `activity-log`, `diffs/{host_id}` (+ `/sync`),
`auth/{login,refresh,logout,me}`, `info`. Unauthenticated health probe at
`/api/health`. Envelope: `{success, data, error{code,message,details},
meta{total,page,page_size}}`.

**Error codes** (`ssm_web/api/errors.ex`): `AUTH_REQUIRED` 401, `INVALID_CREDENTIALS`
401, `VALIDATION_FAILED` 422, `{HOST,USER,KEY,AUTHORIZATION}_NOT_FOUND` 404,
`HOST_DISABLED` 409, `SSH_READONLY` 409, `CONFLICT` 409, `SSH_CONNECT_FAILED` 502,
`INTERNAL_ERROR` 500.

**Auth quick test** (dev server):
```bash
TOKEN=$(curl -sX POST http://localhost:4000/api/v2/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"your_password"}' | jq -r '.data.access_token')
curl -H "Authorization: Bearer $TOKEN" http://localhost:4000/api/v2/hosts
```
Access tokens live 15 minutes, refresh 7 days; token `type` claim prevents cross-use.
`JWT_SECRET` (32+ chars) signs both; `SESSION_KEY` is a legacy fallback name — same
secret as the python stack, so pre-cutover tokens keep working.

**Env vars** (env-only, read in `phoenix/config/runtime.exs`; python-stack names and
defaults preserved): `DATABASE_URL` (or `DATABASE_PATH`), `HTPASSWD`, `SSH_KEY`,
`SSH_KEY_PASSPHRASE`, `SSH_TIMEOUT`, `SSH_CONNECT_TIMEOUT`, `SSH_CONCURRENCY`,
`SSH_CHECK_SCHEDULE`, `SSH_UPDATE_SCHEDULE`, `JWT_SECRET` (fallback `SESSION_KEY`),
`SECRET_KEY_BASE`, `LOGLEVEL`, `PORT`, `LISTEN`, `PHX_HOST`, `POOL_SIZE`.

**Secrets protection**: run `./install-hooks.sh` after cloning (installs
`.githooks/pre-commit` secret scanner; other tools may overwrite
`.git/hooks/pre-commit` — reinstall if in doubt). Server side: GitHub secret scanning +
push protection + `security-scan.yml` (TruffleHog, GitLeaks, Trivy). Legitimate test
fixtures go into `.secrets-whitelist` as `VALUE:` entries or file globs.

**Release pipeline**: tag `v*.*.*` → `release-docker.yml` builds `phoenix/Dockerfile`
for amd64+arm64, pushes to Docker Hub + GHCR with `latest`/semver manifests and
creates a GitHub release. The image applies migrations on start.

**Known open wounds** (documented so you don't re-discover them; fix only when asked):
CHANGELOG.md has leaked AI-tool artifacts near the end (`</xai:function_call...`);
scheduler sweeps (`SSH_CHECK_SCHEDULE`/`SSH_UPDATE_SCHEDULE`) are read but not wired
to jobs — restoring them needs explicit sign-off (rewrite plan §8);
`.secrets-whitelist` still carries Rust- and Python-era
path entries (harmless, narrow — cleaning it needs user approval per rule #6);
`./ssm.db` at the repo root is the final snapshot of the python stack's data, kept as
the dev-DB import source (`just import-db`).

**Knowledge graph**: the `code-review-graph` MCP tools are available and auto-update via
hooks. Use `semantic_search_nodes` / `query_graph` / `get_impact_radius` for cheap
exploration and impact tracing; fall back to Grep/Glob/Read when the graph doesn't
cover what you need, and trust files over the graph on any disagreement.

**Skills**: `verify` (run the gate), `ship` (package a correct commit), `release`
(user-invoked only). The python-era `db-migration` and `add-endpoint` skills were
removed with the python stack.

**History docs**: `docs/elixir-phoenix-rewrite.md` is the rewrite plan (historical,
kept for the record — its "SSM today" sections describe the deleted python stack).
