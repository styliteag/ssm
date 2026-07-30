# Changelog

All notable changes to SSM (Secure SSH Manager) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.0.1] - 2026-07-30

### Fixed
- **LiveView pages work behind a TLS-terminating reverse proxy**: the socket origin check compared the browser's `Origin` against the container's own scheme and port, which never match once a proxy terminates HTTPS — the log filled with `Could not check origin for Phoenix.Socket transport`, the UI silently degraded to long-polling and reconnected in a loop. Setting `PHX_HOST` to the public hostname now switches the check to a hostname comparison; deployments without `PHX_HOST` (reached by IP or LAN name) keep the previous behaviour. Reverse-proxy operators must set `PHX_HOST` — see the commented example in `docker/compose.yml`.

### Removed
- **Dead editor/tooling configs**: the unused Spec-Kit machinery (`.specify/`, the `/specify`-family commands in `.claude/commands/`), Cursor configs (`.cursor/`, `.cursorrules`, and the typo'd `.cursrorules`), `.grok/`, `.opencode.json`, four orphaned knowledge-graph skill notes in `.claude/skills/`, the broken `.envrc` (`use flake` without a `flake.nix` — a Rust-era leftover), `.mcp.json`, and the historical python rewrite plan (`plans/`). Kept: `.claude/settings.json` (code-review-graph hooks) and the `release`/`ship`/`verify` skills.

### Changed
- **`CLAUDE.md` is now a one-line `@AGENTS.md` import instead of a symlink** — the officially recommended, Windows-friendly way to share one agent-instruction file; editors no longer show two identical full files.

### Security
- **GitLeaks in CI actually scans now**: the `gitleaks-action` wrapper had errored softly on every run for lack of an organization license — replaced with the plain (MIT) gitleaks CLI, pinned, full-history. A reviewed `.gitleaks.toml` allowlists known fake test fixtures and documented example values; one real historical finding (a retired dev SSH key briefly committed in April 2026) is deliberately left visible until confirmed dead. Also bumped the workflow's deprecated actions (checkout@v5, codeql upload-sarif@v4).

## [2.0.0] - 2026-07-30

### Removed
- **The Python/FastAPI backend and React frontend are gone**: the Elixir/Phoenix stack is now the only application. Deleted: `backend/` (FastAPI, SQLAlchemy, Alembic, pytest suite), `frontend/` (React SPA), the combined nginx+uvicorn Docker image (`docker/app/`), the python-era dev scripts (`start-dev.sh`, `kill-ports.sh`), stale docs describing the old stacks (`docs/API.md`, `DESIGN.md`, `IMPROVEMENT_PLAN.md`, the Postman collection), and the old-stack SBOMs. The final snapshot of the python stack's database is kept at `./ssm.db` as the dev-DB import source.

### Changed
- **Production Docker deployment now builds the Elixir image** (`docker/compose.yml` → `phoenix/Dockerfile`) — the CI release workflow publishes it too. The data volumes are unchanged (`docker/data/{db,config,keys,logs}` mounted at `/app/{db,config,keys,logs}`): the Elixir image keeps the previous image's mount contract and adopts the existing database in place, so operators keep their data without any migration step. The environment keeps working too (`DATABASE_URL`, `HTPASSWD`, `SSH_KEY`, `JWT_SECRET`/`SESSION_KEY`, `LOGLEVEL`).
- **Simpler `just` commands**: the `elixir-` prefix is gone — `just dev`, `just test`, `just verify`, `just mix <task>`, `just import-db` (the aggregate `verify` gate is now the Elixir `mix precommit`). `just up`/`down`/`logs`/`ps` drive the production compose file; `just docker-build`/`docker-run` exercise the production image locally. `release.sh` no longer bumps python files and verifies the Elixir stack instead.
- **Dev container now mounts `phoenix/keys/`** (was `backend/keys/`) — the SSH key moved with the stack; drop your key at `phoenix/keys/id_ssm`.
- **GitHub releases now carry the real release notes**: the release workflow extracts the version's section from `CHANGELOG.md` into the release body (previously a boilerplate stub with only the image names). Manual workflow re-runs now build the given tag instead of the default branch, and the workflow's actions were bumped to current majors.
- **Production image carries complete OCI labels**: description, url, license (`BUSL-1.1`), and vendor joined the existing title/version/revision/source labels, with defaults so locally built images are label-complete too.
- **`release.sh` leaves a bare `[Unreleased]` section** after rotating the changelog instead of seeding an empty `- ` bullet that could leak into the next release.
- **Diff viewer remembers results and dead hosts fail fast**: sync statuses are cached server-side — revisiting the page shows the last known badges instantly (parity with the React app, which kept them in browser state) and only missing or stale results (older than 5 minutes) are re-checked; a new "Re-check all" button forces a full sweep. Connects also got their own budget: `SSH_CONNECT_TIMEOUT` (default 10s) bounds TCP+handshake, so dead or firewalled hosts no longer hold a check slot for the full `SSH_TIMEOUT` (120s).
- **Host checks run massively parallel and the fan-out is configurable**: the diff viewer's status sweep now checks up to `SSH_CONCURRENCY` hosts at once (new env var, default 32). To make that parallelism real, the SSH connection registry no longer performs handshakes itself — connects (and jump-host forwarder readiness waits) moved into the calling process, so one dead host timing out (up to `SSH_TIMEOUT`, default 120s) no longer stalls every other connection behind it. When two operations race to connect the same host, one connection wins and the other is closed.

### Fixed
- **SSH Keys "host access" counted deleted hosts**: the per-owner host count included grants whose host row is gone (orphans inherited from Diesel-era databases); those are skipped now.
- **Assigning an unknown key without picking a user** ended the LiveView session instead of showing an error; it now says what is missing.
- **Key type badge wrapped and clipped**: long key types (`ssh-ed25519`) broke onto two lines inside the fixed-height badge on the SSH Keys page and got cut off; the badge no longer wraps.
- **Diff viewer showed "checking…" on every host until the slowest one answered**: per-host sync statuses were collected in one all-or-nothing batch, so with a large fleet and a few dead hosts (120s SSH timeout each) no badge appeared for minutes. Results now stream in per host as each check finishes, and up to 8 checks run concurrently (previously 4).
- **Elixir dev server could not reach any host**: the dev container only mounted `phoenix/`, so the SSH key the app expects at `keys/id_ssm` was invisible and every SSH operation failed with `ssh.key_unreadable`. The compose file now mounts the key directory (`phoenix/keys/`) read-only into the container.

### Added
- **Operator upgrade guide** (`docs/UPGRADING.md`): what changes when switching a production deployment from the `1.1.x` python/react image to the Elixir image — TL;DR: bump the image tag; volumes, `DATABASE_URL` (both old forms), `HTPASSWD`, `SESSION_KEY`/`JWT_SECRET`, `SSH_KEY`, port 80, and the `/api/v2` wire format all keep working. Covers the pre-upgrade DB backup, Traefik/WebSocket notes, behavior changes (7-day web sessions), and the rollback path (adoption is non-destructive).
- **License attribution and SBOM regenerate from the shipped Elixir deps**: `just notices` rebuilds `THIRD-PARTY-LICENSES.md` and a CycloneDX 1.6 `sbom.cdx.json` from the phoenix release's runtime dependencies (hex + git deps + the vendored topbar.js) — the file previously still listed the removed python/react dependencies. Dev/test-only tooling is excluded. Ported from the dashboard-open generator.
- **Justfile conveniences**: `just sh` / `just iex` (shell/IEx in the dev container), `just migration <name>` / `just migrate` / `just rollback` (Ecto migration workflow), and an optional gitignored `local.just` for checkout-specific recipes.
- **Card views for hosts, users, and SSH keys**: every list page now has a List/Cards toggle (list stays the default). Host cards show address, status badge, login, jump host, and the grant-count link; user cards keep the selection checkbox for merge/bulk-delete plus key/grant links; key cards show owner, type badge, truncated material, and host access. All row actions (test, edit, delete, split, copy, view, …) are available on the cards too.
- **Diff viewer list view (the default)**: next to the card grid there is now a table view (toggle top-left, choice kept in the URL) with sortable Name / Address / Status / Differences columns, a name-or-address search, the difference count per host, and per-row actions — re-check one host or sync it (with confirmation) without opening its detail first. Clicking a row opens the per-login diff as before.
- **Sortable columns on every list**: hosts, users, SSH keys, and the authorizations list all sort by clicking a column header (click again to flip direction; the header shows the active sort arrow).
- **Authorizations page overhaul**: the list gained stat cards (total / active / inactive / distinct users / distinct hosts), a free-text search across user, host, login, options, and comment, and cross-links everywhere — user and host names filter the list in place, with shortcut icons to the user's keys and the host's diff view. The matrix got the old frontend's look back: user and host search fields, slanted host headers, a sticky user column, compact ✓/✗ cells (names link to the grant list and the diff viewer). The bulk-grant dialog is wider, has per-column search with live selected counts, and a clearer new/existing preview.
- **Hosts page: online/offline status and cross-links**: each host row shows an online/offline/unknown badge (fed from the diff viewer's status cache and from this page's own connection tests — a successful test flips the badge to online immediately, a failure shows offline with the error in the tooltip), status filter pills with counts (Active — the default —, All, Online, Offline, Unknown, Disabled), an authorization count linking to the authorizations page filtered to that host, and a per-host shortcut into the diff viewer.
- **Elixir stack: theme system and production image**: the Phoenix app gained a theme picker (four designs — Orbit, Bench, Soft, Rainbow — each in light and dark, selectable from the sidebar and already active on the sign-in page; choices persist in year-long cookies, and stale cookies from removed themes fall back safely) and a production Dockerfile (`phoenix/Dockerfile`): an Elixir release image that keeps the previous image's operational contract — plain HTTP on :80 (TLS stays at the operator's proxy; `force_ssl` removed for LAN parity), volumes at `/app/db` `/app/config` `/app/keys` `/app/logs`, database migrations applied on start (`Ssm.Release.migrate` — the baseline migration adopts Diesel- and Alembic-era databases in place), `/api/health` healthcheck, OCI image labels, and `openssh-client` in the runtime for jump-host chains and boot-time key decryption.
- **Elixir stack ships the `/api/v2` JSON API** (rewrite plan §7, default "keep"): the python API's full surface reimplemented wire-compatibly in Phoenix — bearer JWT auth (`auth/login`, `auth/refresh`, `auth/logout`, `auth/me`) with the same HS256 signing secret (`JWT_SECRET`/`SESSION_KEY`), claims, and 15-minute/7-day TTLs, so existing API clients and tokens keep working across a cutover; CRUD for `hosts`, `users`, `keys`, `authorizations` with the same field constraints, envelope (`{success, data, error{code, message, details}, meta}`), stable error codes (401 `AUTH_REQUIRED`/`INVALID_CREDENTIALS`, 404 `*_NOT_FOUND`, 409 `CONFLICT`/`HOST_DISABLED`/`SSH_READONLY`, 422 `VALIDATION_FAILED`, 502 `SSH_CONNECT_FAILED`) and semantics (`jump_via` existence/self-jump checks, `?user_id=`/`?host_id=` filters, `{"deleted_id"}` delete payloads); paginated `activity-log`; `info` (version + alembic revision of an adopted database); and `diffs/{host_id}` + `diffs/{host_id}/sync` backed by the same diff engine as the LiveView page, honoring disabled-host and readonly guards. The JWT layer runs on OTP `:crypto` directly — no new dependency. 24 ExUnit contract tests mirror the pytest suite's assertions. Container port parity is in place as well (the Phoenix image listens on :80 like today's image). The scheduler sweeps remain unrestored by design: the python scheduler is vestigial (its env vars are read but never wired to jobs), and restoring the documented behavior needs explicit sign-off (plan §8).
- **Elixir LiveView UI reaches React feature parity**: the remaining React-only tooling is now in the Phoenix app. Users page: rows are selectable with merge (into an existing or a brand-new user; keys move, authorizations are copied with duplicates skipped, sources deleted — all in one transaction) and bulk delete (impact summary of users/keys/authorizations before confirming), plus a per-user split action that moves chosen keys to a new user and copies the authorizations. SSH Keys page: stats bar, type filter pills, free-text search, paste-to-parse add modal (the pasted authorized_keys line is validated against the SSH wire format and the comment becomes the name), multi-line bulk import with a per-line success/error report, and copy-to-clipboard for full key lines. Authorizations page: three views — the list (now with CSV export matching the React columns, downloadable under the active filters), the matrix (users × hosts per login account with usage-sorted selector, root-or-most-used default, view-only "all" counts mode, show-authorized-only toggle, and click-to-grant/revoke cells), and a stats view (totals plus hosts-by-user-access and users-by-host-access rankings); a bulk-grant modal grants a login across a users × hosts selection, skipping pairs already granted, with a live new/existing preview. Diff viewer: an unauthorized key on a host can now be legitimized from the diff — keys of known users get an "Allow" button that grants the login, unknown keys can be assigned to a user (granting the login too); both are database-only changes, the host stays untouched until the next sync. Activities page: free-text search across action/target/actor and structured detail rendering (old→new change chips, summary chips, JSON fallback). Dashboard: version pill showing app version and applied schema revision. New host form pre-fills the SSH login with root. Grants whose user or host row was deleted in a legacy Diesel-era database render as "missing" markers instead of crashing the page. All mutations are audit-logged; ~60 new ExUnit tests cover the ported features.
- **Elixir dev server imports your existing data**: `just dev` now snapshots the repo-root `ssm.db` (the python stack's database) into `phoenix/ssm_dev.db` on first start — previously the Elixir dev server came up with an empty database. The copy uses SQLite's transaction-safe `.backup`, never writes to the source, and only runs when the dev DB has no hosts yet; `just import-db` forces a fresh snapshot at any time.
- **Elixir/Phoenix rewrite groundwork (branch `elixir-rewrite`)**: rewrite plan at `docs/elixir-phoenix-rewrite.md` and a new `phoenix/` app (Phoenix 1.8 + LiveView, SQLite via `ecto_sqlite3`) scaffolded alongside the existing stack, with a docker-only dev toolchain (`phoenix/compose.yml`, port 4000). The Elixir app reads the same environment variables as the Python stack (`DATABASE_URL`, `HTPASSWD`, `SSH_*`, `JWT_SECRET`/`SESSION_KEY`, `LOGLEVEL`, `PORT`, `LISTEN`) and takes its version from the repo-root `VERSION` file. No user-visible behavior changes; the Python/React stack remained the production app during the transition (it has since been removed — see the top of this section). The Elixir stack adopts the existing SQLite database in place: a baseline migration recreates the Alembic-head schema idempotently (fresh DBs get the full schema; Diesel-era and Alembic-era DBs are adopted untouched, verified against a verbatim Diesel-era schema dump). Web sign-in uses session cookies against the same htpasswd file (bcrypt-only, `$2y$` accepted); a password change or user removal now invalidates that user's existing sessions on their next request, and sessions last 7 days instead of silently dying after 15 minutes like the old broken token refresh. The SSH layer is reimplemented on Erlang's built-in `:ssh`/`:ssh_sftp` (no asyncssh): direct hosts connect natively, jump-host chains run through a supervised OpenSSH forwarder, and passphrase-protected keys are decrypted once at boot — with the same per-host connection reuse, read caching, disabled-host and readonly-marker guards, and the identical bundled `script.sh` for authorized_keys operations. The domain logic (hosts, users, keys, authorizations, activity log, and the authorized_keys diff/sync) is reimplemented as Elixir contexts with the same validation, uniqueness, and audit-trail behavior as the Python API. The LiveView UI port has begun: an authenticated app shell with sidebar navigation (same seven pages as the React app) and dark/light/system theme toggle, the Dashboard (entity stat cards plus a recent-activity feed), and the Hosts page (create/edit modal with jump-host selection, enable/disable toggle, delete with confirmation, and an async SSH connection test that refuses disabled hosts). Host mutations write activity-log entries — behavior the Python stack defined but never wired up. The Users page (per-user key/authorization counts, create/edit modal, enable/disable, cascade-aware delete), SSH Keys page (owner filter, add/edit modal — key material immutable after creation, full-key view modal, delete), and Authorizations page (user/host filters, grant/edit/revoke with duplicate-grant rejection) are ported as LiveViews; all mutations audit-log. The Diff Viewer computes per-host sync status asynchronously (synchronized / needs sync with add/remove counts / error / disabled), shows the per-login key diff with readonly and managed-pragma badges, and offers single-host Sync plus a Sync-all that only touches drifted hosts; syncs are audit-logged. The Activities page lists the audit trail newest-first with a type filter, expandable JSON details, and load-more paging. The Elixir app exposes an unauthenticated `GET /api/health` (version + database probe) for container orchestration, and the `justfile` gained targets for the docker-only toolchain (today: `just dev`, `just test`, `just verify`).

## [1.1.11] - 2026-07-29

### Security
- **Frontend dependency advisories**: upgraded React Router to 8.3.0, PostCSS to 8.5.25, and the frontend lint toolchain so all transitive `brace-expansion` paths resolve to 5.0.8, addressing the high-severity vulnerabilities reported by Dependabot and `npm audit`.

### Added
- **Third-party license attribution (`THIRD-PARTY-LICENSES.md`)**: generated NOTICE files enumerating every bundled production dependency with its version, SPDX license, and full license text, satisfying the attribution/notice obligations of those licenses under our BSL 1.1 distribution. All dependencies are permissive (MIT/BSD/ISC/Apache-2.0/PSF) or weak file-level copyleft; `asyncssh` is used under its Eclipse Public License 2.0 option (offered as `EPL-2.0 OR GPL-2.0-or-later`), unmodified, so no copyleft reaches SSM. Two files are produced by `backend/scripts/gen_third_party_licenses.py`: a combined backend+frontend notice at the repository root (shipped in the full-app image, `docker/app/Dockerfile`, alongside `LICENSE`) and a backend-only notice at `backend/THIRD-PARTY-LICENSES.md` (shipped in the standalone backend image, `backend/Dockerfile`). The root `.dockerignore` was adjusted so the notice and `LICENSE` survive into the build context. Regenerate the files after any dependency change.
- **Software Bill of Materials (SBOM)**: machine-readable CycloneDX SBOMs for the production dependency trees, generated by `backend/scripts/gen_sbom.sh` into `sbom/ssm-backend.cdx.json` (Python, 36 components, CycloneDX 1.6) and `sbom/ssm-frontend.cdx.json` (JavaScript, CycloneDX 1.5). Each component carries a Package URL (`purl`) and SPDX license; backend license fields are back-filled from installed metadata by `backend/scripts/enrich_sbom_licenses.py` (the `cyclonedx-py requirements` generator leaves them empty). Enables automated vulnerability/license scanning and supply-chain attestation. Both images ship their SBOMs under `/app/sbom/`: the full-app image (`docker/app/Dockerfile`) carries both files, the standalone backend image (`backend/Dockerfile`) carries the backend SBOM (mirrored into `backend/sbom/` so it reaches that build context). Regenerate after dependency changes.

## [1.1.10] - 2026-06-28

### Added
- 

### Changed
- **License switched to Business Source License 1.1 (BSL 1.1)**: the project is now source-available rather than GPL-3.0-only. You may read, build, modify, and run SSM for your own organization for free, but offering it as a hosted/managed/multi-tenant service or reselling it for a fee requires a commercial license from STYLiTE (office@stylite.de). Each released version automatically converts to GPL v3.0-or-later four years after publication (Change Date 2030-06-28). Added `LICENSE` (BSL text) and `LICENSING.md` (plain-language summary); removed the standalone GPLv3 `LICENSE.txt`; updated the README License section.

### Security
- **Patched 46 Dependabot-flagged dependency vulnerabilities** (22 high, 18 moderate, 6 low). Backend: `asyncssh` 2.22.0→2.24.0, `cryptography`→49.0.0, `pyjwt` 2.12.1→2.13.0, `starlette`→1.3.1, `urllib3`→2.7.0, `idna`→3.18, `mako`→1.3.12 (lockfile; direct-dependency floors for `asyncssh`/`pyjwt` raised in `pyproject.toml`). Frontend: `axios`→1.18.1, `react-router`/`react-router-dom`→7.18.0, `vite`→7.3.6, plus transitive `esbuild`/`js-yaml`/`form-data`/`@babel/core`; `npm audit` now reports 0 vulnerabilities (direct floors raised in `package.json`).

## [1.1.9] - 2026-04-27

### Changed
- **Documentation refresh**: `AGENTS.md`/`CLAUDE.md`, `frontend/README.md`, top-level `README.md`, and the `verify`/`release` skills no longer describe the project as a Rust/Actix/Diesel backend. Commands, endpoint paths (`/api/v2/*`), auth scheme (JWT bearer), SSH library (`asyncssh`), and env vars (`JWT_SECRET`) now match the Python/FastAPI reality. Removed obsolete `jump_via` string-coercion section.
- **Configuration is env-only**: dropped TOML support. Settings come from environment variables, optionally seeded by a `backend/.env` file loaded on startup via `python-dotenv` (override the path with `DOTENV=…`). `config.toml` / `config.toml.example` / the `CONFIG` env var are gone; `backend/.env.example` is the new template. SSH options moved from a `[ssh]` table to flat env vars: `SSH_TIMEOUT`, `SSH_KEY_PASSPHRASE`, `SSH_CHECK_SCHEDULE`, `SSH_UPDATE_SCHEDULE`. `SSH_KEY` and `JWT_SECRET`/`SESSION_KEY` keep their previous names. `start-dev.sh` and the docker compose/setup files were updated to match.

### Added
- 

## [1.1.8] - 2026-04-27

### Changed
- **Contributor docs**: `AGENTS.md`/`CLAUDE.md` now spell out a mandatory rule that every database schema change goes through an alembic migration — never hand-edit models without a matching revision in `backend/migrations/versions/`.

### Fixed
- **Docker bind-mount permissions**: Container startup now `chown`s `/app/db` to the runtime user, so SQLite databases written under the previous uid-1000 backend image remain writable after upgrading to the combined image.

## [1.1.7] - 2026-04-27

### Added
- **Dashboard version pill**: The dashboard now displays the frontend version, backend version, and applied alembic schema revision (`fe v… be v… db <rev>`), with a tooltip showing each on its own line.
- **`/api/v2/info` endpoint**: New protected endpoint returning `{name, version, alembic_revision}`. Frontend version is injected at build time from the repository `VERSION` file via Vite (`__APP_VERSION__`), and the Docker frontend stage copies `VERSION` so the bundle ships with the correct value.

### Fixed
- **Legacy DB stamping creates missing tables**: When stamping a Diesel-era database as revision `0001`, also run `metadata.create_all(checkfirst=True)` to create tables that were added after the Python rewrite (notably `activity_log` and its indexes). Without this, the activity-log API crashed with `no such table: activity_log` on first request.

## [1.1.6] - 2026-04-27

### Fixed
- **Frontend talking to wrong API base**: The production frontend bundle was being built with `VITE_API_URL=/api`, but the FastAPI backend mounts everything under `/api/v2/*`, so login (and every other call) returned 404. The Dockerfile default and both compose files now use `/api/v2`.

## [1.1.5] - 2026-04-27

### Fixed
- **Empty `alembic_version` after fresh upgrade**: SQLite uses non-transactional DDL, so a fresh `alembic upgrade head` would create the schema but the stamp `INSERT` into `alembic_version` was rolled back when the async connection closed. An explicit `connection.commit()` after migrations now persists the revision row.
- **Legacy DB with empty alembic_version table**: Some inherited databases already had an empty `alembic_version` table (created by a prior crashed bootstrap). The previous fix only handled the missing-table case, so alembic still tried to re-run revision `0001` and crashed with `table host already exists`. The stamp logic now also fires when the table is present but empty.

### Security
- **postcss XSS advisory**: Bumped postcss to 8.5.12 to address a published XSS advisory.

## [1.1.4] - 2026-04-27

### Fixed
- **Legacy DB stamping moved into `migrations/env.py`**: Detection now lives inside alembic's environment, so it runs whenever alembic does — regardless of how it is invoked. The previous standalone preflight script and its hook in `start.sh` are removed.

## [1.1.3] - 2026-04-27

### Fixed
- Container startup no longer crashes on databases inherited from the Rust backend. A preflight step detects legacy databases (schema present, no `alembic_version` table) and stamps them as revision `0001` so `alembic upgrade head` becomes a no-op.

## [1.1.2] - 2026-04-27

### Added
- 

## [1.1.1] - 2026-04-27

### Added
- 

## [1.1.0] - 2026-04-27

### Added
- **Authorization Matrix "All" View**: Added "all (view only)" option to login account selector that displays the count of authorizations per user/host across all login accounts
- **Authorization Matrix Usage Counts**: Login accounts in selector now show usage count (e.g., "oracle (4)")
- **User Merge Workflow**: Users list now supports selecting multiple accounts and merging them into a single user, consolidating keys and host authorizations in one step
- **Bulk User Deletion**: Select users in the list and delete them all at once with a confirmation dialog that summarizes impact

### Changed
- **Authorization Matrix UI**: Removed scroll bars from matrix view for cleaner, full-page display
- **Authorization Matrix Layout**: Moved "Show Authorized Only" button to be positioned after the login account selector for better workflow
- **Authorization Matrix Selector Order**: Login accounts sorted by usage count in descending order, with "all (view only)" shown first
- **Authorization Matrix Default**: Smart default selection - prefers "root" if available, otherwise defaults to most-used login account
- **Host Add Form**: SSH Username field now defaults to "root" for convenience 

## [1.0.1] - 2025-10-06

### Added
-

## [1.0.0] - 2025-10-06

### Changed
- **Database Schema Consolidation**: Removed all incremental migrations and created single initial migration with final schema
- **Breaking Change**: Existing databases must be recreated - migration history removed for clean 1.0.0 baseline

### Added
- **Initial Migration**: Single migration file containing complete database schema for version 1.0.0

## [0.2.22] - 2025-10-06

### Added
- **Authorization Matrix Enhancement**: Added login account selector to filter matrix by specific SSH accounts (root, oracle, etc.)
- **Smart Host Filtering**: Matrix automatically shows only hosts that have authorizations for the selected login account
- **Alphabetical Sorting**: Users and hosts are now sorted alphabetically for better overview
- **Show Authorized Only Toggle**: Added button to show only users with actual authorizations, hiding empty rows
- **Code Quality Improvements**: Fixed multiple Clippy and ESLint warnings across frontend and backend

### Changed
- **Matrix Behavior**: Matrix now defaults to showing all users but only relevant hosts for selected login account
- **User Experience**: Cleaner matrix interface with better filtering and sorting

## [0.2.21] - 2025-10-06

### Added
- 

## [0.2.20] - 2025-10-06

### Added
- Expanded username validation to allow spaces, @ symbols, and # symbols
- Allow empty comments in user edit modal

## [0.2.19] - 2025-10-06

### Added
- 

## [0.2.18] - 2025-10-06

### Added
- Comprehensive CHANGELOG.md file for tracking all changes
- Automatic CHANGELOG.md updates in release.sh script

## [0.2.17] - 2025-09-13

### Added
- **Environment Variable Support**: Full support for `DATABASE_URL`, `HTPASSWD`, `SSH_KEY`, and `SESSION_KEY` environment variables that take precedence over config file settings
- **Automatic Htpasswd Creation**: Server automatically creates htpasswd file with random admin password if none exists, displayed in beautiful ASCII art during startup
- **Enhanced SSH Key Error Handling**: Detailed error messages with step-by-step SSH key generation instructions using ed25519 keys
- **Comprehensive Startup Logging**: Server now logs database URL, htpasswd path, SSH key path, and log level during startup for transparency
- **Config File Optional**: Server can start without `config.toml` using sensible defaults and environment variables
- **Docker Environment Configuration**: Proper environment variable setup in docker-compose.yml with detailed comments

### Changed
- **Configuration Loading**: Environment variables now override config file settings for all critical paths
- **Default SSH Key Path**: Changed from `/app/id` to `keys/id_ssm` for better Docker compatibility
- **Error Messages**: All error messages now use beautiful box drawing characters for better readability
- **Documentation**: Updated README.md, CLAUDE.md, and config examples with comprehensive environment variable documentation

### Fixed
- **CORS Configuration**: Confirmed that `cors_origins` config setting is unused (server uses hardcoded localhost origins)
- **SSH Key Path Resolution**: Consistent default paths across development and Docker environments

### Security
- **Automatic Password Generation**: Secure random password generation using cryptographically secure RNG
- **Bcrypt Hashing**: All auto-generated passwords use proper bcrypt hashing with default cost factor

## [0.2.16] - 2025-09-13

### Changed
- Update .gitignore to exclude backup files with .bak extension

### Fixed
- Reposition logout button in sidebar for improved accessibility
- Move logout button under user info section in sidebar

## [0.2.15] - 2025-09-13

### Changed
- Update Nginx configuration to comment out rate limiting for SSH and API endpoints

## [0.2.14] - 2025-09-13

### Refactored
- Enhance authorization mapping in UsersPage for type safety
- Update UsersPage to use RawAuthorizationResponse type for improved type safety

## [0.2.13] - 2025-09-13

### Fixed
- Resolve TypeScript compilation errors for production build

### Changed
- Update dependencies in package.json and package-lock.json
- Update Cargo.toml dependency versions
- Remove deprecated test files and modules

### Security
- Remove git-secure wrapper script that enforced SSH commit signing
- Enforce SSH commit signing and update dependencies

## [0.2.12] - 2025-09-XX

## [0.2.11] - 2025-09-XX

## [0.2.10] - 2025-09-XX

---

## Development Notes

### How to Update This Changelog

1. **Before committing**: Add new changes under `[Unreleased]` section
2. **When releasing**: Move `[Unreleased]` items to new version section with date
3. **Version format**: Use semantic versioning (MAJOR.MINOR.PATCH)
4. **Categories**:
   - `Added` for new features
   - `Changed` for changes in existing functionality
   - `Deprecated` for soon-to-be removed features
   - `Removed` for now removed features
   - `Fixed` for any bug fixes
   - `Security` for vulnerability fixes

### Recent Changes Made (2025-09-13 Session)

This changelog was created as part of a major enhancement session that included:
- Environment variable configuration system
- Auto-generation of credentials
- Improved error handling and user experience
- Docker configuration improvements
- Comprehensive documentation updates

**Note to self**: Always update CHANGELOG.md when making significant changes. Use the git history to reconstruct changes if needed.</contents>
</xai:function_call">Create CHANGELOG.md with comprehensive documentation of all changes.
