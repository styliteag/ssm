# SSM — Operating Manual for Coding Agents

`CLAUDE.md` is a symlink to this file. This is not a project description — it is the
operating manual. Follow it literally. When this file and the code disagree, the code
wins; fix this file in the same commit and say so.

**Product**: Secure SSH Manager — a web app that manages `authorized_keys` files across
many hosts. React 19 + TypeScript frontend, Python 3.12 + FastAPI backend, SQLite via
SQLAlchemy 2.0 async + Alembic. JWT auth backed by an htpasswd file.

**History you must know**: SSM was a Rust/Actix/Diesel app, fully rewritten in Python.
Rust ghosts remain in docs, file trees, and old configs. There is **no `Cargo.toml`**,
no TOML config, no CSRF. If you find a reference to any of those, it is stale — do not
act on it (see mistake #14).

---

## 1. Orientation

| Path | What lives there |
|------|------------------|
| `backend/src/ssm/api/v2/` | One FastAPI router per domain (auth, hosts, users, keys, authorizations, diffs, activity_log, info). Request/response Pydantic models are defined **inside** the router file. |
| `backend/src/ssm/core/` | `envelope.py` (`ApiResponse[T]`), `errors.py` (`ErrorCode` enum + `AppError` hierarchy), `exception_handlers.py` |
| `backend/src/ssm/auth/` | `jwt.py` (HS256, access 15 min / refresh 7 days), `htpasswd.py`, `deps.py` (`get_current_user`, `protected_router()`) |
| `backend/src/ssm/db/` | `models.py` (SQLAlchemy 2.0 declarative), `deps.py` (`db_session` — commits for you), `session.py`, `base.py` |
| `backend/src/ssm/ssh/` | `protocol.py` (`SshClient` Protocol), `asyncssh_client.py` (prod), `caching.py`, `mock.py` (tests), `safety.py` (readonly markers), `script_runner.py` |
| `backend/src/ssm/scheduler/` | APScheduler jobs (`SSH_CHECK_SCHEDULE` / `SSH_UPDATE_SCHEDULE`) |
| `backend/migrations/` | Alembic. `env.py` contains the legacy Diesel-DB stamping logic — read it before touching migrations. |
| `backend/tests/` | `unit/`, `contract/` (HTTP-level, in-memory DB, mock SSH), `integration/` (one real-asyncssh test). **There is no `e2e/` directory.** |
| `frontend/src/services/api/` | Axios client (`base.ts`) + per-domain services. The only place HTTP happens. |
| `frontend/src/contexts/` | Auth / Notification / Theme React Contexts — the only global state. |
| `frontend/src/types/index.ts` | Hand-maintained mirror of backend Pydantic models. No codegen, no Zod. |
| `frontend/src/components/ui/` | Reusable primitives (Button, Input, Card, Modal, Form, DataTable, SearchableSelect, Tooltip, Loading). |
| `justfile` | The command interface. Prefer `just <target>` over raw commands. |

**Data model** (SQLite, table names are singular — Diesel parity): `host`, `user`,
`user_key`, `authorization`, `activity_log`. `authorization` links user↔host with a
remote `login`. `host.disabled` blocks all SSH operations. `activity_log.meta` maps to
a column literally named `metadata`.

**Request path**: Bearer JWT → `protected_router()` dependency (`get_current_user`) →
handler → `db_session` (yields session, **commits on success, rolls back on exception**)
→ `ApiResponse[T]` envelope. SSH goes through the `SshClient` Protocol resolved from
`app.state`, never imported concretely in routers.

## 2. Commands

```bash
just dev                 # backend :8000 + frontend :5173
just verify              # THE quality gate: ruff, mypy --strict, bandit, pytest, eslint, tsc
just backend-test -k x   # subset of tests
just migrate             # alembic upgrade head
just migrate-new "desc"  # alembic revision --autogenerate
just docker-run          # combined prod image on :8080
cd backend && uv run pytest tests/contract/test_hosts_routes.py::test_create_then_get
```

CI has **no test/lint/typecheck gate** — only secret scanning and Trivy. `release.sh`'s
own test step is commented out. `just verify` on your machine is the only quality gate
that exists. Treat it as mandatory, not advisory.

## 3. Non-negotiable rules

1. **Every schema change ships an Alembic migration** in the same commit as the model
   change. Never `metadata.create_all()` or hand-written DDL against a prod-shape DB.
2. **Every commit updates `CHANGELOG.md`** under `[Unreleased]`, Keep-a-Changelog
   sections, user-visible wording. (Releases 1.1.4–1.1.7 shipped empty because commits
   skipped this; it was backfilled by hand. Don't repeat that.)
3. **Every v2 response uses the `ApiResponse[T]` envelope**; failures raise an
   `AppError` subclass carrying a stable `ErrorCode`. Never a bare `HTTPException`,
   never a free-form error string the frontend would have to parse.
4. **Every SSH-touching code path checks `host.disabled` first** and honors the remote
   readonly markers (`.ssh/system_readonly`, `.ssh/user_readonly` → `SSH_READONLY`).
5. **`just verify` passes before you call anything done.** All six gates.
6. **Never `git commit --no-verify`.** Never weaken `.githooks/pre-commit` or
   `.secrets-whitelist` without explicit user approval.
7. **Versions are bumped only by `./release.sh`** (updates `VERSION`,
   `backend/pyproject.toml`, `uv.lock`, rotates the CHANGELOG, tags, pushes). Never
   edit those version fields by hand.
8. **Work lands on `main`** in Conventional-Commit style: `<type>(<scope>): imperative
   subject` — types: feat, fix, refactor, docs, test, chore, perf, ci. No co-author
   trailers.
9. **Immutability**: frozen dataclasses in Python; spreads / functional `setState`
   updaters in TypeScript. Never mutate objects in place.
10. **No new `console.*` or `print()`** in production code paths. Use the configured
    logging on the backend.

## 4. Conventions

### Backend

- Router file layout (canonical example: `api/v2/hosts.py`): module docstring, Pydantic
  `XxxOut` with `ConfigDict(from_attributes=True)`, `CreateXxxRequest` /
  `UpdateXxxRequest` with `Field` constraints, a `_get_or_404` helper, handlers with
  `response_model=ApiResponse[...]` returning `ApiResponse[...].ok(...)`.
- PATCH semantics: `payload.model_dump(exclude_unset=True)`, apply with `setattr`.
- Uniqueness violations: catch `IntegrityError` around `session.flush()`, raise
  `Conflict`. Then `session.refresh(obj)` before serializing.
- **`flush()`, never `commit()`, inside handlers** — `db_session` commits when the
  handler returns (see mistake #7).
- New failure modes: add an `ErrorCode` member + `AppError` subclass in
  `core/errors.py`. Reuse existing codes when they fit.
- Dependencies live on `app.state`, are injected via `Annotated[T, Depends(...)]`, and
  are typed against Protocols (`SshClient`), not implementations.
- Config: env vars only, loaded once in `config.py` (`.env` via python-dotenv; shell
  wins). Frozen dataclasses. Add new knobs there, document them in §8.
- Style gates: ruff (with `S`, `ASYNC`, `PTH`, `SIM`, `PL` rule families, line length
  100, double quotes) and `mypy --strict` over `src` **and** `tests` (tests are only
  exempt from `disallow_untyped_defs`).

### Frontend

- All HTTP through `services/api/*`; components never import axios. Services unwrap the
  v2 envelope and return `{success, data}`; the stable `error.code` is only available
  on the **thrown** error (`err.code`, `err.status`) — branch in `catch`.
- Global state = the three Contexts. Local state = `useState` with functional updaters.
  **Do not add Zustand stores** (see mistake #4) or any new state library.
- Types: when you change a backend response/request model, update
  `frontend/src/types/index.ts` and the affected service in the same change. There is
  no codegen to catch drift — you are the codegen.
- UI: compose from `components/ui/`; Tailwind semantic tokens (`bg-background`,
  `text-foreground`, `surface-*`) so dark/light both work; `lucide-react` icons;
  Linear-style weights via `.font-w510` / `.font-w590`. Schema-driven `ui/Form` for
  simple entity forms.
- Numeric optional fields follow the `jump_via` pattern: form holds a string, convert
  once on submit to `number | null`. Never send `""` as "no value".

### Tests

- New/changed endpoint → contract test in `tests/contract/` using the `auth_client` /
  `auth_headers` fixtures (in-memory SQLite, real migrations-equivalent schema,
  `MockSshClient`, real JWT). Assert on `status_code`, `body["success"]`, envelope
  `data`/`meta`, and `error.code` for failures. Always include one unauthenticated
  401 `AUTH_REQUIRED` test.
- Pure logic → `tests/unit/`. Real network SSH → only `integration/test_asyncssh_real.py`.
- pytest runs with `asyncio_mode = "auto"` — async tests need no decorator.
- Frontend has **no test framework**. Do not scaffold one as a side effect; propose it
  as its own task.

### Process (added conventions — follow these too)

- Prefer extending an existing pattern over introducing a new library or abstraction.
  One precedent file is worth more than a better idea.
- New page logic goes into components/services, not into the four giant pages
  (`DiffPage`, `KeysPage`, `HostsPage`, `UsersPage` — 900–1400 lines each). Don't grow
  them; carve out instead when you must touch them.
- Document what **is**, not what is planned. Several frontend types/endpoints are
  aspirational leftovers; don't add more.
- When you fix a stale doc statement, note it in the commit body.

## 5. Named mistakes — what you will get wrong here, and the rule that prevents it

1. **The Schema Drift.** Editing `db/models.py` and calling it done. *Rule: no model
   change without a migration in `backend/migrations/versions/` in the same commit.
   Use the `db-migration` skill.*
2. **The Silent Release.** Committing without a CHANGELOG entry; the release then ships
   with empty notes. *Rule: `CHANGELOG.md` is staged in every commit (rule #2). The
   `ship` skill enforces this.*
3. **The Envelope Break.** Returning a bare dict, raising `HTTPException(detail=...)`,
   or inventing an error string. The frontend switches on `error.code`, not messages.
   *Rule: `ApiResponse[T]` + `AppError` subclasses only; new codes go into `ErrorCode`.*
4. **The Zustand Mirage.** Zustand is in `package.json` but has **zero** usages —
   earlier docs claimed otherwise. *Rule: state via React Context + `useState` only;
   never add a store because a dependency exists.*
5. **The Refresh Illusion.** Assuming token refresh works. It does not: axios rejects
   non-2xx before the 401 check in `base.ts` ever runs, so `refreshAccessToken` and
   `authService.refresh` are unreachable dead code; expiry (15 min) effectively logs
   the user out. *Rule: do not build features that rely on silent refresh. Fixing it
   requires a response interceptor (or `validateStatus`) plus repairing the
   single-flight guard — treat that as its own reviewed task.*
6. **The Fake Pagination Trust.** Services fabricate `PaginatedResponse` client-side;
   the backend returns plain arrays and ignores `page`/`per_page`. *Rule: never assume
   server-side pagination, search, or filtering exists — check the service first.*
7. **The Handler Commit.** Calling `session.commit()` inside a handler. `db_session`
   commits after the handler yields back. *Rule: `flush()` + `refresh()` in handlers;
   commit belongs to the dependency.*
8. **The key_name Trap.** TypeScript uses `key_name`; the wire uses `name`. The remap
   lives in `services/api/keys.ts` (and `users.ts`). *Rule: keep the remap in the
   service layer; never leak `key_name` onto the wire or `name` into components.*
9. **The Empty-String Sentinel.** Sending `jump_via: ""` (or any `""`-for-null). The
   backend expects `int | null`. *Rule: convert form strings once on submit to
   `number | null` (see `HostEditModal.tsx`).*
10. **The Legacy DB Amnesia.** Writing a migration that works on a fresh DB but crashes
    on inherited Diesel-era DBs. `migrations/env.py` stamps legacy DBs as `0001` and
    runs `metadata.create_all(checkfirst=True)` first — which pre-creates **all**
    current-metadata tables, so a later revision's plain `op.create_table` will crash
    with "table already exists" on the legacy path. *Rule: every migration must pass
    the three-way matrix (fresh / legacy / downgrade) in the `db-migration` skill; new
    tables in revisions > 0001 need an existence guard or an `env.py` adjustment.*
11. **The Real SSH Call.** Importing `asyncssh` in a router or writing a test that
    opens a connection. *Rule: routers speak only to the `SshClient` Protocol; tests
    use `MockSshClient` via the `mock_ssh` fixture; the single real-SSH test stays in
    `integration/`.*
12. **The Disabled Host Bypass.** Adding an SSH operation that skips the `disabled`
    check or readonly markers. *Rule: every new SSH path raises `HostDisabled` (409)
    for disabled hosts and `SshReadOnly` (409) when markers are present — with a
    contract test proving it.*
13. **The Version Hand-Bump.** Editing `VERSION` or the `pyproject.toml` version, or
    tagging manually. *Rule: only `./release.sh` (interactive — it prompts; never run
    it headless or unasked).*
14. **The Rust Ghost.** Acting on stale artifacts: `Cargo.toml` references in old docs,
    `backend/config.toml` (dead — config is env-only), `frontend/src/services/csrf.ts`
    (dead), `*.rs` patterns in `.secrets-whitelist`, v1 API shapes. *Rule: the backend
    is Python, the API is `/api/v2/*`, config is env vars. Stale references get fixed
    or ignored, never obeyed.*
15. **The cn() Merge Assumption.** `cn()` is plain `clsx` — **no** tailwind-merge.
    Appending a conflicting utility does not override the earlier one. *Rule: don't
    rely on class-override behavior; restructure the classes instead.*
16. **The build:prod Blind Spot.** `npm run build:prod` skips `tsc`. *Rule: type-check
    is a separate mandatory gate (`just frontend-typecheck`); lint runs with
    `--max-warnings 0`, so warnings are failures.*
17. **The e2e Phantom.** Placing tests in a `tests/e2e/` directory because old docs
    mentioned one. *Rule: HTTP-level tests go in `tests/contract/`.*
18. **The StrictMode Double-Fire.** Adding a `useEffect` that fires network calls and
    wondering why dev hits the API twice. *Rule: React StrictMode double-invokes
    effects in dev — make mount effects idempotent or guarded.*
19. **The Trusting-CI Fallacy.** Seeing green GitHub checks and assuming tests passed.
    CI runs security scans only. *Rule: quality is proven exclusively by local
    `just verify`.*
20. **The Whitelist Symlink Gap.** Assuming this file is exempt from the secrets hook.
    `.secrets-whitelist` lists `CLAUDE.md`, but what gets staged is `AGENTS.md` — which
    is **not** whitelisted. *Rule: keep secret-shaped strings out of this file; reuse
    the exact example values already present in the repo when documenting.*

## 6. Quality bar per deliverable — checkable, not adjectives

### Any commit
- [ ] `just verify` exits 0 (ruff, mypy --strict, bandit, pytest, eslint, tsc — all six).
- [ ] `CHANGELOG.md` staged with an entry under `[Unreleased]` in the correct section,
      written as what a user/operator would notice.
- [ ] Message matches `<type>(<scope>): <imperative subject>`; no co-author trailer.
- [ ] `git diff --staged` contains no new `console.`/`print(`, no secrets, no
      commented-out code blocks, no version-field edits.
- [ ] If `db/models.py` is in the diff, a `migrations/versions/` file is too.

### Backend endpoint / feature
- [ ] Router built on `protected_router()` (only `auth/login` + `auth/refresh` are public).
- [ ] `response_model=ApiResponse[...]`; success via `.ok(...)`, list endpoints set `Meta(total=...)`.
- [ ] Failures raise `AppError` subclasses; any new code added to `ErrorCode`.
- [ ] Contract tests cover: 401 unauthenticated (`AUTH_REQUIRED`), happy path incl.
      envelope shape, each domain error (404/409) by `error.code`.
- [ ] No new `# type: ignore` without an inline reason.
- [ ] SSH involved → `HostDisabled` + `SshReadOnly` paths tested with `MockSshClient`.

### Database migration
- [ ] Sequential revision file; `upgrade()` and a working `downgrade()` (or a comment
      explaining why downgrade is impossible).
- [ ] Passes on a fresh DB, on a simulated legacy Diesel DB, and survives
      `downgrade -1` → `upgrade head` (commands in the `db-migration` skill).
- [ ] Schema-altering ops use batch mode semantics compatible with SQLite
      (`render_as_batch` is on; constraints must be named).
- [ ] Model change + migration + CHANGELOG in one commit.

### Frontend change
- [ ] `npm run lint` (0 warnings) and `npm run type-check` pass.
- [ ] HTTP only via `services/api`; error handling branches on caught `err.code`.
- [ ] `types/index.ts` matches the backend contract touched by this change.
- [ ] Works in both themes (semantic tokens used; verified in dark + light).
- [ ] No new dependency; no mutation of state.

### Release (only when the user explicitly asks)
- [ ] Working tree clean; `[Unreleased]` non-empty; run `./release.sh patch|minor|major`
      interactively; report the new tag and the Actions run URL.

### Docs
- [ ] Describes current behavior (verified against code this session), not plans.
- [ ] Stale statements you found are fixed in the same commit and mentioned in its body.

## 7. When uncertain — exact escalation rules

**Stop and ask the user before:**
1. Any migration that drops or renames a table/column, or any operation on a database
   file that is not a throwaway test DB (includes `ssm.db` files in the working tree).
2. Changing the wire format of an existing endpoint (renaming/removing fields, changing
   types, changing an `ErrorCode`) — deployed frontends depend on it.
3. Touching auth semantics: JWT claims/TTLs, htpasswd handling, which routes are public.
4. Adding a dependency to `backend/pyproject.toml` or `frontend/package.json`.
5. `./release.sh`, `git push`, tagging, or anything that triggers CI publishing.
6. `--no-verify`, editing `.githooks/`, or editing `.secrets-whitelist`.
7. Deleting or rewriting files you did not create this session (beyond the edit asked for).

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
`authorizations`, `activity-log`, `diffs/*`, `auth/{login,refresh,logout,me}`, `info`.
OpenAPI at `/api/v2/docs`. Envelope: `{success, data, error{code,message,details}, meta{total,page,page_size}}`.

**ErrorCode enum** (`core/errors.py`): `AUTH_REQUIRED` 401, `INVALID_CREDENTIALS` 401,
`FORBIDDEN` 403, `VALIDATION_FAILED` 422, `{HOST,USER,KEY,AUTHORIZATION}_NOT_FOUND` 404,
`HOST_DISABLED` 409, `SSH_READONLY` 409, `SSH_CONNECT_FAILED` 502, `CONFLICT` 409,
`INTERNAL_ERROR` 500.

**Auth quick test**:
```bash
TOKEN=$(curl -sX POST http://localhost:8000/api/v2/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"your_password"}' | jq -r '.data.access_token')
curl -H "Authorization: Bearer $TOKEN" http://localhost:8000/api/v2/hosts
```
Access tokens live 15 minutes, refresh 7 days; token `type` claim prevents cross-use.
`JWT_SECRET` (32+ chars) signs both; `SESSION_KEY` is a legacy fallback name.

**Backend env vars** (env-only; `backend/.env` seeded via python-dotenv, shell wins):
`DATABASE_URL`, `HTPASSWD`, `SSH_KEY`, `SSH_KEY_PASSPHRASE`, `SSH_TIMEOUT`,
`SSH_CHECK_SCHEDULE`, `SSH_UPDATE_SCHEDULE`, `JWT_SECRET` (fallback `SESSION_KEY`),
`LOGLEVEL`, `PORT`, `LISTEN`, `DOTENV`, `CORS_ORIGINS`. Frontend build: `VITE_API_URL`
(prod default `/api/v2`), `VITE_APP_VERSION` (injected from `VERSION`).

**Secrets protection**: run `./install-hooks.sh` after cloning (installs
`.githooks/pre-commit` secret scanner; note that other tools may overwrite
`.git/hooks/pre-commit` — reinstall if in doubt). Server side: GitHub secret scanning +
push protection + `security-scan.yml` (TruffleHog, GitLeaks, Trivy). Legitimate test
fixtures go into `.secrets-whitelist` as `VALUE:` entries or file globs.

**Release pipeline**: tag `v*.*.*` → `release-docker.yml` builds amd64+arm64, pushes to
Docker Hub + GHCR with `latest`/semver manifests and creates a GitHub release. The
combined image (`docker/app/Dockerfile`) runs nginx :80 + uvicorn, applies
`alembic upgrade head` on start.

**Known open wounds** (documented so you don't re-discover them; fix only when asked):
CHANGELOG.md has leaked AI-tool artifacts near the end (`</xai:function_call...`);
frontend token refresh is dead code (mistake #5); `backend/config.toml` is a dead file;
`LoginPage.tsx` hardcodes "v1.0.0" while the dashboard shows the real injected version;
`services/api/index.ts` barrel omits `activitiesService` and `diffApi`; CI lacks a
test gate.

**Knowledge graph**: the `code-review-graph` MCP tools are available and auto-update via
hooks. Use `semantic_search_nodes` / `query_graph` / `get_impact_radius` for cheap
exploration and impact tracing; fall back to Grep/Glob/Read when the graph doesn't
cover what you need, and trust files over the graph on any disagreement.

**Skills**: `verify` (run all gates), `ship` (package a correct commit), `db-migration`
(safe schema change), `add-endpoint` (full-stack endpoint scaffold), `release`
(user-invoked only).
