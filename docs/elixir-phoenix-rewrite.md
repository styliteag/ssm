# Plan: SSM Rewrite to Elixir/Phoenix LiveView

Status: DRAFT for review — nothing in here is started except M0 (done).
Date: 2026-07-30. This is a plan document; it intentionally describes future
work. Where it states facts about the current codebase, each was verified
against the tree on 2026-07-30 at commit `0ee29cf`.

---

## 0. Context and precedents

SSM today: React 19 + TypeScript frontend (16,398 LOC, 8 pages), Python 3.12 +
FastAPI backend (2,605 LOC src, 3,816 LOC tests, 28 endpoints across 8 routers),
SQLite via SQLAlchemy 2.0 async, exactly one Alembic revision (`0001`), JWT auth
against an htpasswd file, asyncssh for host access.

Two in-house precedents de-risk this rewrite:

- **`../link-shortener`** (app `:orbitly`): Phoenix 1.8.9 + LiveView 1.2,
  `ecto_sqlite3` in production, plain-GenServer background jobs, session-cookie
  auth, docker-only toolchain (no local Elixir), `mix release` image.
- **`../dashboard`** (`orbit/`): full LiveView rewrite of a React+FastAPI app.
  Playbook ("Anlauf 2", `dashboard-open/docs/elixir-liveview-rewrite.md`):
  parallel rebuild against the same DB, black-box contract suite as gate,
  cutover as environment flip, python stack kept warm until after probation,
  teardown last. Also: dual-mode baseline migration that adopts a legacy
  Alembic-owned schema (stamp on existing DB, create on fresh DB).

Estimated result size: ~8–10k LOC `lib/` (orbitly is 6k for a smaller domain;
orbit is 41k for a much larger one).

## 1. Goals / non-goals

Goals:
- One language, one runtime, one release artifact. Phoenix serves UI and API;
  the nginx+uvicorn split in the combined image disappears.
- Feature parity with today's app, gated by tests, not by adjectives.
- Keep operator experience: same env-var names where possible, same
  drop-in-image upgrade path, migrations applied on boot.

Non-goals (explicitly out of scope during the port):
- No new features before cutover. PubSub live host-status streaming is the
  obvious post-cutover win; it is not part of parity.
- No redesign of the UI. Same pages, same flows, daisyUI-flavored styling is
  acceptable drift (as in both precedents).
- No auth-model invention beyond JWT→session (see §6).

## 2. Database decision: SQLite vs MariaDB, and sequencing

**DECIDED 2026-07-30 (user): SQLite via `ecto_sqlite3`, no MariaDB, Phase A
cancelled.** The Elixir stack adopts the existing `ssm.db` in place (§5).
The analysis below is kept for the record.

Earlier user preference (2026-07-30): move to MariaDB, ideally before the rewrite.

Counterpoints, for the record, before committing:
- SSM is 5 small tables, one instance, low write volume. `ecto_sqlite3` is
  proven in production by orbitly. SQLite is not a technical blocker.
- The single-container drop-in image is an operator-facing *feature*. MariaDB
  makes the minimum deployment two containers plus credentials, backups, and
  startup ordering.
- Every existing installation needs a one-time data migration.

Argument for MariaDB-first anyway: it converts this rewrite into an exact
replay of the dashboard playbook — both stacks pointed at the same MariaDB
server, schema ownership handed over in place at cutover, and the awkward
"two stacks sharing one SQLite file" problem in parallel dev disappears.
The dashboard baseline-migration and boot-migrator code (MyXQL) can be reused
nearly verbatim instead of being re-derived for SQLite.

**Decision: Phase A (MariaDB enablement) runs first, in the Python stack:**
1. Add MariaDB support to the current backend: `DATABASE_URL` already exists;
   add `asyncmy`/`aiomysql` dependency, verify Alembic `0001` on MySQL dialect
   (constraint names are already explicit — good), CI matrix job.
   Note: `migrations/env.py` legacy-Diesel stamping is SQLite-only by nature;
   MariaDB databases are always fresh-from-import, so the stamping path stays
   SQLite-only.
2. Ship a one-shot importer (CLI: read SQLite file, write MariaDB) modeled on
   orbitly's kutt importer. Row-for-row copy; five tables; verify counts +
   spot-check hashes. `apscheduler_jobs` is NOT imported (see §8 finding).
3. Release as a normal Python release. SQLite remains the default; MariaDB is
   opt-in via `DATABASE_URL`. Operators migrate at their own pace.
4. The Elixir stack then targets **MyXQL only**. Cutover requires the operator
   to be on MariaDB first. The importer remains in the final image (Elixir
   reimplementation, M4) so SQLite-era installs can jump directly.

Fallback (if Phase A is dropped): Elixir uses `ecto_sqlite3`, same file,
orbitly-style. Everything else in this plan is unchanged; only §5's baseline
migration targets SQLite and parallel dev needs care with the single writer.

## 3. Target stack

| Concern | Choice | Precedent |
|---|---|---|
| Framework | Phoenix ~> 1.8, LiveView ~> 1.2, Bandit | both |
| DB | Ecto + MyXQL (Phase A) | orbit |
| Assets | mix-managed esbuild + Tailwind 4 + daisyUI, no Node | both |
| Auth | Phoenix session cookies vs htpasswd file | both (see §6) |
| SSH | stdlib `:ssh`/`:ssh_sftp` + OpenSSH forwarder for jumps | M0 spike |
| Jobs | one supervised GenServer, self-rescheduling | both |
| Toolchain | docker-only, `just` targets, `mix precommit` | both |
| Versioning | repo-root `VERSION` read in `mix.exs`; `./release.sh` unchanged | both |

Naming (open decision, default): OTP app `:ssm`, modules `Ssm.*` / `SsmWeb.*`,
directory `phoenix/` at repo root next to `backend/` and `frontend/` until
teardown.

## 4. Component mapping (verified against current tree)

| Today (Python/React) | Target (Elixir) |
|---|---|
| `api/v2/*` routers, Pydantic models | Contexts: `Ssm.Hosts`, `Ssm.Users`, `Ssm.Keys`, `Ssm.Authorizations`, `Ssm.Activity`, `Ssm.Diffs` + LiveViews; JSON API per §7 decision |
| `core/envelope.py` `ApiResponse[T]` | only if API kept: one JSON view module rendering the same envelope |
| `core/errors.py` `ErrorCode` + `AppError` | error tuples/exceptions carrying the same stable codes (API) / flash+form errors (LiveView) |
| `db/models.py` (5 tables, singular names, `activity_log.metadata` column) | Ecto schemas; `field :meta, :string, source: :metadata`; keep constraint names from `0001` |
| `db/deps.py` commit-per-request | Ecto `Repo` per-operation; `Repo.transaction` where a handler does multi-step writes |
| `auth/jwt.py`, `auth/deps.py` | session plug + `on_mount` hooks (LiveView); Joken HS256 only if API kept |
| `auth/htpasswd.py` (bcrypt-only, `$2y$`→`$2b$` normalize, malformed lines skipped, missing file = empty store) | 1:1 port on `bcrypt_elixir`; same normalize, same reject-non-bcrypt rule |
| `ssh/protocol.py` `SshClient` Protocol | `Ssm.Ssh.Client` behaviour: `connect/1`, `exec/3` (with stdin), `read_file/2`, `write_file/3`, `close/0`; `SshTarget` struct with recursive `jump_target` |
| `ssh/asyncssh_client.py` (conn pool per host_id, `known_hosts=None` today = no host-key verification) | GenServer per host holding the `:ssh` connection; `silently_accept_hosts: true` for parity |
| `ssh/caching.py` (memoise `read_file` per host_id+path, invalidate on write) | ETS table in front of the client, same key + invalidation |
| `ssh/script_runner.py` + `ssh/script.sh` | `script.sh` carries over **verbatim** (it is the whole remote-side story: getent home lookup, BSD/pfSense/TrueNAS/Sophos detection, readonly probe, pragma). Runner ports 1:1: `version` (sha256 self-check), upload via `exec` + stdin (`cat > .ssm/script.sh`), `get_ssh_keyfiles` (JSON), `set_authorized_keyfile` (stdin, "readonly" in stderr → `SshReadOnly`) |
| `ssh/safety.py` readonly markers | same markers, same 409 semantics |
| `ssh/mock.py` + `mock_ssh` fixture | mock module implementing the behaviour, injected via app config in tests |
| `scheduler/` APScheduler + SQLAlchemyJobStore | one GenServer; cron parsing for `SSH_CHECK_SCHEDULE`/`SSH_UPDATE_SCHEDULE` (see §8 finding first) |
| `frontend/src/services/api/*`, `types/index.ts` | deleted concept — LiveView has no client API layer; the `key_name`↔`name` remap (mistake #8) and hand-mirrored types die with it |
| React Contexts (Auth/Notification/Theme) | session auth, Phoenix flash + LiveView push events, daisyUI `data-theme` cookie (orbitly pattern) |
| `components/ui/*` | function components (`core_components.ex` style) |
| recharts (`components/dashboard/DashboardCharts.tsx` only) | small inline SVG charts or a vendored chart hook (orbit vendored xterm the same way) |

## 5. Schema adoption / migrations

Only one Alembic revision exists (`0001`); `migrations/env.py` stamps
Diesel-era DBs and pre-creates missing tables with `create_all(checkfirst)`.
Ecto side (dashboard pattern, simplified because head == baseline):

- One baseline migration replaying the `0001` schema as `CREATE TABLE IF NOT
  EXISTS` in FK order, with named constraints (`unique_address_port`,
  `unique_user_host_login`, `user_enabled_bool`, `activity_log_type_check`,
  `idx_activity_log_timestamp`, `idx_activity_log_type`, unique
  `user.username`, `host.name`, `user_key.key_base64`).
- On an imported/adopted DB every statement no-ops and the version is stamped;
  on a fresh DB it creates everything. Port orbit's `refuse_destructive!`
  guard and irreversible `down`.
- `alembic_version` (and `apscheduler_jobs`, if present) are left in place;
  dropping them is a post-cutover cleanup task requiring explicit approval.
- Boot-time migrator as supervised child before the Endpoint (orbit
  `migrator.ex`, incl. bounded DB-wait), replacing the container's
  `alembic upgrade head` startup step.
- `activity_log.timestamp` server default `strftime('%s','now')` is
  SQLite-specific — Phase A must map it (`UNIX_TIMESTAMP()`) or move the
  default into application code; decide in Phase A step 1.

## 6. Auth

- LiveView sessions: login form posts to a plain controller (session cookies
  need a request/response cycle — orbit `session_controller` pattern),
  credential check against the htpasswd store (reloaded per login attempt,
  matching today's `HtpasswdStore.reload` semantics — verify current reload
  timing in M5 before locking this).
- JWT disappears for the UI. Access/refresh TTLs, the `type` claim, and the
  dead frontend refresh path (mistake #5) all become irrelevant.
- `JWT_SECRET`/`SESSION_KEY` env var is repurposed as
  `secret_key_base` seed material so operators don't need new secrets
  (validate length ≥ 64 bytes requirement; derive via KDF if shorter).
- If the JSON API is kept (§7): Joken HS256 bearer tokens with the same
  claims, so existing API clients keep working unchanged.

## 7. JSON API: keep or drop (decision gate, default = keep)

Evidence of API-as-contract: `docs/API.md`, `docs/postman/` collection.
Unknown: external consumers beyond the React app.

Default: **keep the `/api/v2` surface** (28 endpoints — thin CRUD over the
same contexts LiveView uses, plus envelope + Joken). Payoff: the existing
3,816-LOC pytest contract suite becomes a black-box cutover gate — point it
at the Phoenix server via a base-URL fixture (dashboard's `CONTRACT_BASE_URL`
trick) and green means wire-level parity, including `error.code` values.
Deprecation of the API can be decided after cutover with usage data.

If the user rules out external consumers: drop the API, port the contract
suite's assertions into ExUnit LiveView tests instead (more work, less
certainty — the gate then proves the new stack against itself).

## 8. Scheduler — finding first, port second

**Finding (2026-07-30):** `SSH_CHECK_SCHEDULE` and `SSH_UPDATE_SCHEDULE` are
loaded into config but consumed nowhere; no `add_job` call exists;
`poll_connection_status` is implemented and tested but never registered. The
APScheduler instance starts empty (persisted jobstore aside). CLAUDE.md §8
presents these as live knobs — stale doc, to be fixed independently.

Port decision: implement the two sweeps in Elixir as *intended* (check =
`poll_connection_status` semantics: connect to every non-disabled host, count
reachable/failed/skipped_disabled; update = apply expected `authorized_keys`
via the diff/sync path), honoring the documented env vars — this restores the
documented behavior rather than porting the vestigial state. Needs explicit
user sign-off since it is behavior the current deployment does not actually
execute. GenServer with cron parsing; no Oban, no persisted jobstore.

## 9. Ops parity

Env vars (same names, same defaults as `config.py` unless noted):
`DATABASE_URL` (Phase A: MySQL form), `HTPASSWD` (default `.htpasswd`),
`SSH_KEY` (default `keys/id_ssm`), `SSH_KEY_PASSPHRASE`, `SSH_TIMEOUT`
(default 120), `SSH_CHECK_SCHEDULE`, `SSH_UPDATE_SCHEDULE`, `JWT_SECRET`
(fallback `SESSION_KEY`), `LOGLEVEL` (RUST_LOG-style directives — port the
mapping), `PORT`, `LISTEN`, `CORS_ORIGINS` (API only). `DOTENV` dies (no
python-dotenv; document `.env` handling via compose/just instead).

Image: single-stage-served Phoenix release (no nginx, no uvicorn). Today's
image exposes :80 — keep :80 for drop-in parity (root inside container like
today's nginx master, or `setcap` on beam; decide in M1). Healthcheck: `GET
/api/health` (new, unauthenticated, replaces wget check). OCI labels exactly
as today (`org.opencontainers.image.version` from build-arg + revision/
source/title — ouroboros reads them). `alembic upgrade head` startup step
replaced by the boot migrator. `release.sh`, tag-triggered
`release-docker.yml` (amd64+arm64, Docker Hub + GHCR), CHANGELOG discipline:
unchanged. THIRD-PARTY-NOTICES/SBOM regeneration for Hex deps (dashboard did
the same on cutover).

## 10. Milestones

Each milestone lands on `main` behind the unchanged production stack; nothing
user-visible changes until M8. `just verify` gains Elixir gates in M1
(`mix precommit`: compile --warnings-as-errors, format, test).

- **Phase A — MariaDB enablement (Python stack)**: driver, dialect-clean
  migration, importer CLI, CI job, release, operator docs. Gate: full pytest
  suite green on both SQLite and MariaDB; importer round-trip test.
- **M0 — SSH spike**: DONE 2026-07-30. Stdlib `:ssh` covers direct hosts
  (connect/exec/sftp/markers vs OpenSSH 10). Two fallbacks proven: encrypted
  openssh-key-v1 keys need boot-time `ssh-keygen -p` decrypt (no
  `ed25519_pass_phrase` option in OTP 27/29); jump chains need a spawned
  OpenSSH `ssh -N -L` forwarder (native `tcpip_tunnel_to_server` + nested
  Erlang client hangs on OTP 27 and 29). Residual M3 items: `exec` with
  stdin piping (`:ssh_connection.send` + EOF) — script upload and
  `set_authorized_keyfile` depend on it; behavior under `SSH_TIMEOUT`.
- **M1 — Skeleton**: `phoenix/` app, docker-only toolchain, `just` targets,
  Dockerfile (release, VERSION layer-cache trick, OCI labels), CI build job,
  health endpoint. Gate: image boots, healthcheck green.
- **M2 — Schema + adoption**: Ecto schemas, baseline migration, boot
  migrator, Elixir importer (SQLite→MariaDB). Gate: three-way matrix — fresh
  DB / imported production copy / downgrade-refusal — plus round-trip vs a
  real `ssm.db` copy.
- **M3 — SSH layer**: behaviour, per-host connection GenServers, ETS read
  cache with write invalidation, forwarder supervision for `jump_via` chains,
  `script.sh` runner port, mock for tests. Gate: M0 lab (kept in
  scratchpad/reproducible compose) green against the Elixir implementation;
  readonly + disabled-host refusal tests.
- **M4 — Contexts + API**: domain logic (hosts/users/keys/authorizations/
  activity/diffs incl. `sync`), envelope + Joken if §7 default holds. Gate:
  pytest contract suite black-box green against Phoenix (excluding
  auth-mechanism-specific tests, ported separately).
- **M5 — Auth**: session login/logout, htpasswd store, `on_mount` guards.
  Gate: login/logout/expiry ExUnit tests; bcrypt `$2y$` file verified.
- **M6 — LiveViews**: 8 pages, ui components, both themes. Gate: manual
  parity walkthrough per page against the running Python stack, checklist
  committed (dashboard's parity-gaps audit, but *before* cutover).
- **M7 — Scheduler + hardening**: §8 sweeps (after sign-off), load/soak on a
  host fleet copy, `LOGLEVEL` mapping, docs rewrite (README, CLAUDE.md §1/§8,
  API.md), CHANGELOG.
- **M8 — Cutover**: operator switches image tag; boot migrator adopts the DB.
  Python stack stays released and warm (previous tag) for rollback during
  probation. Teardown of `backend/` + `frontend/` in a separate commit only
  after probation — dashboard lost tooling in its teardown commit; check
  nothing rides along (e.g. anything reading `backend/` paths in scripts,
  `.secrets-whitelist` patterns, `install-hooks.sh`).

## 11. Testing / gates summary

- Contract: pytest suite re-pointed at Phoenix (M4 gate) — the single
  strongest parity signal we own; keep it runnable until teardown.
- ExUnit: DataCase/ConnCase per orbitly's shape; DB tests `async: false`
  (MyXQL sandbox); mock SSH via behaviour swap; one real-SSH test kept in an
  opt-in integration tag, mirroring `integration/test_asyncssh_real.py`.
- No dialyzer promise: mypy --strict rigor is lost; compensate with
  `--warnings-as-errors`, contract suite, and typespecs on the SSH behaviour
  and context public functions.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Fleet has SSH servers/key types the lab didn't cover | M3 gate includes a read-only sweep (`connect` + `get_ssh_keyfiles`) against the real inventory from a dev checkout before M6 starts |
| `exec`+stdin quirk in Erlang `:ssh` | first task in M3; OpenSSH-Port fallback covers it too if needed |
| MariaDB migration burdens small installs | SQLite stays supported in the Python stack until cutover; importer ships in both stacks; comms in release notes |
| Cutover regressions à la dashboard (bootstrap not ported, fields never read) | pre-cutover parity checklist (M6), contract suite (M4), probation with warm rollback (M8) |
| Silent scope growth in LiveView pages | pages port 1:1; any improvement ideas go to a post-cutover list in this doc |
| `release.sh`/CI entanglement with `backend/pyproject.toml` versioning | M1 dry-run of `./release.sh` flow against the new layout before anything depends on it |

## 13. Open decisions (owner: user)

1. MariaDB Phase A: confirmed? (counterpoints in §2 — this plan assumes yes)
2. JSON API keep/drop (§7, default keep)
3. Scheduler sweeps: restore documented behavior that is currently not wired (§8)
4. App/dir naming (`phoenix/`, `:ssm` default)
5. Container port :80 parity vs :4000-style non-root (§9)
6. Post-cutover: drop `alembic_version`/`apscheduler_jobs` tables (needs
   explicit approval per CLAUDE.md §7)

## 14. Rollback

Until M8: production stack untouched; every milestone is repo-internal.
At M8: rollback = previous image tag. Phase A DB stays valid for the Python
stack at all times (it is the same schema); the Elixir baseline migration adds
only `schema_migrations`, which the Python stack ignores. No destructive
DB operation is permitted anywhere in this plan without separate approval.
