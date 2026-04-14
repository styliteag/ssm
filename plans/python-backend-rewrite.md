# Plan: Rewrite Backend in Python + FastAPI

Branch: `grill-me`. Driver: current Rust/Actix backend is not maintainable by the sole owner (does not read Rust). Goal: equivalent functionality on a Python stack the owner can evolve.

## Locked Decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Driver | Personal maintainability |
| 2 | Strategy | Big-bang rewrite on branch |
| 3 | DB | Fresh Alembic migrations, one-shot data copy, Diesel retired |
| 4 | SSH | AsyncSSH + Python port of `CachingSshClient` |
| 5 | Auth | JWT (access + refresh), `passlib[bcrypt]` reads existing `.htpasswd` |
| 6 | API | Clean v2 under `/api/v2/*` — pluralized resources, `jump_via: int \| None` |
| 7 | Response | `ApiResponse[T] = {success, data, error, meta}` + enumerated error codes |
| 8a | Layout | Rename `backend/` → `backend-rust/`; new `backend/` is Python; delete `backend-rust/` at merge |
| 8b | Tooling | uv, Python 3.12, ruff, mypy --strict, bandit, pytest, pytest-asyncio, httpx |
| 9 | Tests | Protocol-based SSH with mock + testcontainers integration + httpx contract tests, 80% coverage |
| 10 | Scheduler | APScheduler (AsyncIOScheduler) + SQLAlchemyJobStore, started in FastAPI `lifespan` |
| 11 | Deploy | Multi-stage Dockerfile (uv, non-root), same compose/release/CI, multi-arch preserved |
| 12 | Cutover | Hard cutover, rollback = redeploy prior Rust tag |

## Stack

- **Framework**: FastAPI (async)
- **ORM**: SQLAlchemy 2.0 async + Alembic
- **Validation**: Pydantic v2
- **SSH**: AsyncSSH
- **Auth**: JWT via `pyjwt`, bcrypt via `passlib`
- **Scheduler**: APScheduler (async) with SQLAlchemy job store
- **Test**: pytest, pytest-asyncio, httpx ASGI client, testcontainers for real-SSH integration
- **Lint/Format**: ruff, mypy --strict, bandit
- **Python**: 3.12

## Package Layout

```
backend/
├── pyproject.toml           # uv-managed
├── uv.lock
├── Dockerfile               # multi-stage, non-root
├── alembic.ini
├── migrations/              # Alembic
├── src/ssm/
│   ├── main.py              # FastAPI app + lifespan
│   ├── config.py            # env + config.toml loader
│   ├── core/
│   │   ├── envelope.py      # ApiResponse[T], error codes enum
│   │   ├── errors.py        # exception → envelope mapping
│   │   └── logging.py
│   ├── auth/
│   │   ├── jwt.py           # encode/decode, refresh
│   │   ├── htpasswd.py      # bcrypt verify against .htpasswd
│   │   └── deps.py          # FastAPI Depends(get_current_user)
│   ├── db/
│   │   ├── session.py       # async engine + session factory
│   │   ├── models.py        # SQLAlchemy models
│   │   └── repos/           # repository pattern per entity
│   │       ├── host.py
│   │       ├── user.py
│   │       ├── key.py
│   │       └── authorization.py
│   ├── ssh/
│   │   ├── protocol.py      # SshClient Protocol/ABC
│   │   ├── asyncssh_client.py
│   │   ├── mock.py          # MockSshClient for tests
│   │   ├── caching.py       # CachingSshClient wrapper
│   │   └── safety.py        # readonly sentinels, disabled flag checks
│   ├── api/v2/
│   │   ├── __init__.py      # v2 router mount
│   │   ├── auth.py          # /api/v2/auth/{login,logout,refresh,me}
│   │   ├── hosts.py         # /api/v2/hosts
│   │   ├── users.py         # /api/v2/users
│   │   ├── keys.py          # /api/v2/keys
│   │   ├── authorizations.py
│   │   ├── diffs.py         # /api/v2/diffs/{host_id}
│   │   └── activity_log.py  # /api/v2/activity-log
│   ├── scheduler/
│   │   ├── setup.py         # APScheduler init
│   │   └── jobs.py          # poll host connection status
│   └── activity_logger.py
├── tests/
│   ├── conftest.py          # fixtures: app, db, mock_ssh, testcontainers_ssh
│   ├── unit/
│   ├── integration/         # real SSH via testcontainers
│   └── contract/            # httpx ASGI, ApiResponse[T] shape per endpoint
└── scripts/
    └── migrate_from_rust.py # one-shot Diesel-SQLite → Alembic-SQLite copy
```

## Execution Phases

**Phase 0 — Branch setup**
- [x] `git checkout -b grill-me`
- [x] `git mv backend backend-rust`
- [x] Scaffold `backend/` (pyproject.toml via `uv init`, ruff/mypy/bandit configs, empty package)

**Phase 1 — Foundation** (TDD throughout, all modules ≤400 lines)
- [x] Config loader (env > config.toml; `DATABASE_URL`, `JWT_SECRET`, `SSH_KEY`, `HTPASSWD`, `CONFIG`, `RUST_LOG` → Python logging)
- [ ] `ApiResponse[T]` envelope + `ErrorCode` enum (`AUTH_REQUIRED`, `HOST_DISABLED`, `SSH_READONLY`, `HOST_NOT_FOUND`, `VALIDATION_FAILED`, etc.) + global exception handlers
- [ ] SQLAlchemy models mirroring current schema; Alembic initial migration reproducing it 1:1
- [ ] `scripts/migrate_from_rust.py` (reads `backend-rust/*.sqlite`, writes new DB, verifies row counts)

**Phase 2 — Auth**
- [ ] `passlib` htpasswd verification against existing `.htpasswd`
- [ ] JWT issue/verify (access 15min, refresh 7d), `JWT_SECRET` env
- [ ] Endpoints: `POST /api/v2/auth/login`, `POST /api/v2/auth/refresh`, `POST /api/v2/auth/logout`, `GET /api/v2/auth/me`
- [ ] `Depends(get_current_user)` guarding all non-auth routes; 401 returns `ApiResponse` with `AUTH_REQUIRED`

**Phase 3 — SSH subsystem**
- [ ] `SshClient` Protocol (connect, exec, read_file, write_file, close)
- [ ] `AsyncSshClient` implementation with jump-host support mapping to `Host.jump_via`
- [ ] `MockSshClient` with scriptable responses for unit tests
- [ ] `CachingSshClient` wrapper — connection pool keyed by host, `authorized_keys` read cache with explicit invalidation on write
- [ ] Safety layer: respect `.ssh/system_readonly`, `.ssh/user_readonly`, `host.disabled` — raise typed errors that map to `SSH_READONLY` / `HOST_DISABLED`
- [ ] testcontainers integration test: spin up `linuxserver/openssh-server`, verify connect/exec/readonly/jumphost paths

**Phase 4 — Routes** (each with contract tests asserting envelope shape)
- [ ] `/api/v2/hosts` — CRUD; `jump_via: int | None` (no more string hack); `disabled` flag
- [ ] `/api/v2/users` — CRUD
- [ ] `/api/v2/keys` — CRUD
- [ ] `/api/v2/authorizations` — links user↔host with remote username
- [ ] `/api/v2/diffs/{host_id}` — returns `HOST_DISABLED` error if disabled; otherwise SSH reads+diffs `authorized_keys`
- [ ] `/api/v2/diffs/{host_id}/sync` — blocks if disabled or readonly
- [ ] `/api/v2/activity-log` — paginated list, `meta.total/page/page_size`

**Phase 5 — Scheduler + activity log**
- [ ] APScheduler `AsyncIOScheduler` + `SQLAlchemyJobStore(url=DATABASE_URL)`, start/stop via lifespan
- [ ] Periodic job: poll connection status for all non-disabled hosts
- [ ] `log_activity(action, actor, target, details)` helper, called from routes; async SQLAlchemy insert

**Phase 6 — OpenAPI + frontend cutover**
- [ ] Confirm FastAPI-generated `/api/v2/openapi.json` + `/api/v2/docs`
- [ ] Rewrite `frontend/src/services/api/` for v2: pluralized paths, Bearer-token interceptor, refresh flow, `unwrap<T>(ApiResponse<T>)` helper
- [ ] Drop `String(host.jump_via)` conversion in `hostsService`
- [ ] Update any UI that read error messages to branch on `error.code` instead

**Phase 7 — Deploy**
- [ ] `backend/Dockerfile`: stage 1 `python:3.12-slim` + uv build venv; stage 2 copy venv + source, non-root user, `uvicorn ssm.main:app --host 0.0.0.0 --port 8000`
- [ ] Update `docker/compose.prod.yml` build context / image
- [ ] Verify GH Actions multi-arch build on `v*.*.*` tags still works (cryptography wheels for arm64 confirmed on PyPI)

**Phase 8 — Cutover**
- [ ] All tests green, ≥80% coverage, `ruff`, `mypy --strict`, `bandit` clean
- [ ] Run `scripts/migrate_from_rust.py` against prod DB snapshot in staging; smoke-test
- [ ] Merge commit deletes `backend-rust/`
- [ ] Tag `v2.0.0` → CI builds + publishes images
- [ ] Deploy; if broken, redeploy prior tag + restore pre-cutover DB snapshot

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| AsyncSSH behavior differs from russh (key parsing, jump-host semantics) | testcontainers integration tests cover connect/exec/jumphost/readonly before Phase 4 |
| Alembic migration drifts from Diesel schema | Generate migration, then `sqldiff` or manual compare against Rust-produced DB |
| JWT rollout breaks frontend login | Frontend API client rewrite is part of the same cutover commit, not split |
| Activity log gaps between old/new | Copy script includes activity_log table; new writes start cleanly post-cutover |
| cryptography wheel missing on arm64 | PyPI publishes manylinux_aarch64 wheels — verified before merge |
| SQLite concurrency under async | Use `aiosqlite` + `StaticPool` for single-writer; keep current SQLite-default posture |

## Out of Scope

- No switch from SQLite default (keep PG/MySQL support via SQLAlchemy dialects as today)
- No UI redesign
- No new features — feature parity only
- No Redis/broker (APScheduler in-process is sufficient)
- No Kubernetes manifests (docker-compose remains the deploy unit)
