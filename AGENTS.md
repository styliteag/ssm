# SSM — Operating Manual for Coding Agents

`CLAUDE.md` imports this file (`@AGENTS.md` — Claude Code's include syntax); edit
only AGENTS.md. This is not a project description — it is the operating manual.
Follow it literally. When this file and the code disagree, the code wins; fix this
file in the same commit and say so.

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
| `phoenix/lib/ssm/` | Domain contexts: `hosts.ex`, `users.ex` (+ `user_key`, `key_parser`, `bulk_ops`), `authorizations.ex`, `grants.ex` (+ `expansion`, `drift_check`), `diffs.ex` (+ `status_cache`, and the persisted periodic check: `host_checks`, `sync_check`, `sync_scheduler`), `activity.ex`, `auth/` (htpasswd, JWT token), `release.ex` (prod migrate) |
| `phoenix/lib/ssm/ssh/` | `client.ex` (behaviour), `erlang_client.ex` (prod), `mock_client.ex` (tests), `safety.ex` (readonly markers), `script_runner.ex`, `cache.ex` |
| `phoenix/lib/ssm_web/live/` | One LiveView per page: dashboard, hosts, users, keys, authorizations, grants, diff, activities, login |
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
remote `login`. `host.disabled` blocks all SSH operations. `operators` (OIDC web accounts) and newer tables for the mctl
contract are plural (contract spec names): `customers`, `groups`, `host_groups`, plus
the `mctl_contract` library's `mctl_tokens`, `mctl_jobs`, `mctl_idempotency`, and `host_checks`
(last result of the periodic key check per host, `ON DELETE CASCADE`), and `managed_logins`
(every `(host, login)` that ever held a grant; written by `Authorizations.create_authorization/1`,
`ON DELETE CASCADE` — a sync empties such a login's file after its last grant is gone; pruned only by
`Ssm.Hosts.ManagedLogins.forget/4`: admin "Managed logins" on the hosts page or `DELETE
/api/v2/hosts/{id}/managed-logins/{login}`, only without authorizations and when `script.sh
has_keyfile` says the host has no file for it — an unknown login or missing home answers `unknown`,
exit 1, never "no"; asked again under the host lock right before the delete — audited
`forget_login`; residual race: a file someone creates on the host after that last answer is not
seen).
**Grants** (ADR-0012 phase 2, `Ssm.Grants`, `Ssm.Grants.Expansion`, page `/grants`): table `grants`
(`ssh_user_id`, `customer_id` XOR `group_id`, the creator's scope as id lists `scope_customer_ids` /
`scope_group_ids` — nil = all, `login`, `comment`, `created_by`; all FKs `ON DELETE CASCADE`) is
expanded into `authorization` rows with `grant_id` (FK cascade; nil = manual row). Every trigger
(grant create/delete, `Hosts.update_membership/3` incl. host create, host delete, contract customer
merge/delete/rename and group delete/rename, manual row update/delete) runs
`Expansion.reconcile/2` — a full, idempotent per-host reconcile — in its own IMMEDIATE transaction
(`Ssm.Grants.transaction/1`). A manual row wins; grant rows are read-only (`{:error, :grant_row}`,
API 409 `CONFLICT`). Rows a reconcile removes mark the host in `pending_revocations`
(`Ssm.Diffs.Revocations`, Hosts page badge; also a deleted manual row) until a fully successful sync
clears exactly the mark it read at its start. `SSM_REVOCATION_SYNC=on` (default off) adds the
removal-only sync (`Ssm.Diffs.RevocationSync`, `Diffs.removal_sync_reported/2`): marks made in a
transaction are collected per process and started by the outermost `Ssm.Grants.transaction/1` after
commit (dropped on rollback), async under `Ssm.Diffs.TaskSupervisor`, one per host (`:global.trans`);
it keeps the host's own lines whose key is still authorized, never adds, skips logins without a file
and unread (linked) files, honours disabled/readonly/unsafe/own-key; audited as `ssm (revocation
sync)`, `mode: removal_only`. Tests: `config :ssm, :revocation_sync_runner, :inline`. Every outer
transaction that touches authorizations uses `Ssm.Grants.transaction/1` (IMMEDIATE). Audit:
`grant_create|grant_delete`, `grant_add|grant_remove|grant_move` (trigger, `grant_id`, `job_id`,
`request_id`); the actor is the ctx actor, else the process actor (`Ssm.Grants.put_actor/1`, set by
`UserAuth` on LiveView mount and by the `/api/v2` auth plug), else `ssm`.
`Ssm.Grants.DriftCheck` logs drift every 15 min (`config :ssm, :grants_drift_check`, off in tests).
Who may create: admin any; operator only targets in its scope (`{:error, :out_of_scope}`); others
`{:error, :forbidden}`. Migration `20261109100000` has no `down` (SQLite cannot drop an FK column).
Sync and readonly markers (`Ssm.Diffs.sync_host/2`): a host-wide marker (`system_readonly`, vendor
platform) stops a sync before any write; a login's own `~/.ssh/user_readonly` counts only when root
owns it (`script.sh` `user_readonly_state`, `find -user 0`) and then skips only that login, the
others are written and the sync fails with `{:ssh_readonly, _}` naming skipped and written logins (a
partial sync, API 409 `SSH_READONLY`). A `user_readonly` owned by anyone else is ignored (reported as
`readonly_ignored`, shown in the diff and the audit entry); the marker must be a plain file with one
link, and its content is never shown (fixed reason `user_readonly (root-owned)`). `script.sh` runs as
root and never reads or writes through a link. A symlinked/hardlinked/non-regular `authorized_keys`
is reported `unsafe` (`symlink|hardlink|special`), not read, but still written: the entry is
replaced, never written through, so revocation reaches it. A login without `~/.ssh` gets one at write time
(`script.sh` `ensure_ssh_dir`: only in a home that exists and is no symlink, `mkdir` under
umask 077, then a `pwd -P` re-check inside the new directory and `chown` of the cwd to the
getent uid:gid — never a path — only while the cwd is still empty, root-owned, owner rwx and no
group/other bits; refused when the home's parent is writable by the login (owner, primary group
or world; uid 0 exempt)); a missing or symlinked home is refused `unsafe (home)`, a sync
skips that login ("no usable home"). `set_authorized_keyfile <login> <ssh_user>` (`ScriptRunner` passes
`target.username`; a blank one is refused before SSH, an SSH user getent does not know is
`unsafe (ssh_user)`) refuses a login other than the SSH user whose resolved home (`pwd -P`) is
the SSH user's (`unsafe (shared_home)`, uid-0 aliases like `toor`): that file holds ssm's own
key, which ssm places by login name (`host.username`) — a sync skips such a login ("not
managed: shares the SSH user's home"). A symlinked `~/.ssh` (or one resolving
outside the home) is `unsafe: ssh_dir`: not read, not written, skipped by a sync as "revocation
blocked: unsafe ~/.ssh" (diff, periodic check, audit). Writes: cwd-pinned in the real `~/.ssh`, a
fresh `O_EXCL` temp file (umask 022: root-owned 0644, as before), a handwritten file renamed to
`authorized_keys.backup.<random>`, final rename with `mv -T`/`mv -h`; without either (busybox) a
symlink target is `rm`'d first, then plain `mv` (a real directory there is refused, `unsafe:
link-to-dir`, a per-login skip). An unsafe `~/.ssh` also sets the login's `read_error` (API diff);
`SyncCheck` keeps it as blocked drift, not a host error. Reads: time-bounded; on Linux the opened fd is checked via
`/proc` (same inode as the entry, one link).
Every sync outcome is audit-logged (`Ssm.Diffs.SyncAudit`). Sync, `KeyRemoval`, `Mctl.People`
scrub and `ManagedLogins.forget` run under one per-host lock (`Ssm.Hosts.WriteLock`, `:global`);
the listing reports each file's `sha256` and a write passes it back (`set_authorized_keyfile
<login> <ssh_user> <sha256>`): a file changed since the read is refused `(stale)`, a sync skips
the login. Diff page "Remove" / "Remove all extra keys"
(`Ssm.Diffs.KeyRemoval`, events `remove-key`/`remove-extra-keys`): reads the login fresh,
re-diffs it (`Diffs.login_diff_for_write/2`, refuses without the own key like a sync), drops
only lines still `extra_on_host` and writes the rest through `set_authorized_keyfile`;
readonly/unsafe logins refused, audited (`remove_keys`/`remove_keys_failed`, fingerprints only).

**Web login** (ADR-0011, `lib/ssm/oidc/`, `ssm_web/oidc_controller.ex`): `.htpasswd`
users are local admins (session `ssm_user`). With `OIDC_ISSUER` set, SSO users are
`Ssm.Accounts.Operator` rows (table `operators`, roles admin/operator/viewer; named so
because `Ssm.Users.User` is the SSH target user), session `operator_id`, checked
against the row on every request/mount (disabled, `session_revoked_at`, absolute
expiry). `viewer` is read-only through one allow-list, `SsmWeb.ReadOnly` — a new
LiveView write event is blocked for viewers by default; add only read-only events to
its `@read_events`. Tests use the fake provider in `test/support/fake_oidc_provider.ex`
via `SsmWeb.OIDCCase`. Logout (`UserAuth.log_out_user/1`): after the local session ends, an
OIDC operator is redirected to the provider's `end_session_endpoint` (RP-initiated logout,
`Ssm.OIDC.Logout`; query `client_id`, `post_logout_redirect_uri` = ssm's sign-in URL,
`id_token_hint`) unless `OIDC_RP_LOGOUT` is `false`/`0`/`off`/`no` (default on), the provider
has no such endpoint or its discovery cannot be read — then the normal sign-in redirect.
A random `state` is always added. `id_token_hint` comes from the raw ID token of the login: at
most 1500 bytes it sits in the session encrypted (`Plug.Crypto`, salt `ssm oidc id_token_hint v1`),
larger ones in `Ssm.OIDC.TokenStore` (ETS, TTL = `OIDC_SESSION_MAX_HOURS`, deleted at logout) with
only a random reference in the session; never logged. `.htpasswd` users are unaffected. `/api/v2` bearer tokens are independent of all this.

**Operator scope** (ADR-0012 phase 1, `Ssm.OIDC.Roles`, `Ssm.Accounts.scope/1`): every OIDC
login carries `orbit_customers` and `orbit_groups` (host-group slugs); each must be exactly
`["*"]` or a non-empty slug list (a mixed `["*", "x"]` is malformed). `operator`/`viewer` with
a missing or malformed claim are refused; only `OIDC_GROUPS_DEFAULT=*` lets a missing groups
claim count as `*`. `admin` is global: missing claims count as `*`, a non-`*` scope is refused
(no downgrade). Refusals are audited as `oidc.login_refused` with `reason`
(`customers_missing|customers_malformed|groups_missing|groups_malformed|admin_scoped`, plus the
older ones). Unknown slugs are dropped and logged. Both lists are stored on the operator
(`customers`, `groups`, JSON) and overwritten at every login; a role or scope change
disconnects open LiveViews, and the periodic re-check ends a view whose scope changed. The
session's `current_user` carries `scope` (`Ssm.Scope`; local `.htpasswd` users: global).
`Ssm.Scope` is the only place that turns a scope into queries (`filter/3`, `hosts/1`,
`fetch_host/2`, `in_scope?/2`): a host is in scope when (customers `*` or its customer listed)
and (groups `*` or ≥1 of its groups listed); hosts without customer/group only for `*`. Context
functions that take a `%Ssm.Scope{}` first (`Hosts.list_hosts/1`, `get_host/2`,
`Authorizations.list_authorizations/2`, `create_/update_/delete_authorization`, `bulk_grant/5`,
`Activity.list/2`, `HostChecks.stored/1`, counts) serve the web UI; the scope-less ones stay
global for `/api/v2`, the mctl contract and background jobs. Every LiveView passes
`Scope.of(current_user)` and re-reads the host through the scope in every event (never from
mount-time assigns); an out-of-scope id acts as a missing one ("not found"). Scoped users
cannot create hosts or pin all host keys, and `Hosts.update_host/3` drops their changes to the
connection fields (`address`, `port`, `username`, `key_fingerprint`, `jump_via`) and refuses a
host other hosts jump through (`:jump_host`); only admins set `jump_via` (jump hosts are global).
`Hosts.delete_host/2` refuses a jump host in use for every UI user (`jump_via` cascades), as mctl
does. Bulk grant intersects client-sent host ids with the scope. Permissive authorized_keys options
(`Options.admin_only/1`: `environment`, `cert-authority`, `user-rc`, `permitopen`, `permitlisten`,
`pty`, `port-forwarding`, `agent-forwarding`, `X11-forwarding`, `tunnel`, `no-touch-required`) are
admin-only on the scoped write paths: `create_/update_authorization` and `bulk_grant` take
`role:` in `opts` (`Options.validate_role/2`, fails closed without a role; a comment-only edit of
an admin's grant passes, moving it does not); the scope-less `/api/v2` path is unchanged.
Activity entries of a host carry `activity_log.host_id` (cleared by `Hosts.delete_host/1`, SQLite
reuses ids); a scoped user sees those of hosts in scope plus its own hostless ones. SSH user catalog: every web user
reads all SSH users and keys; a scoped user changes a user, its keys, split/merge/bulk delete and
diff-page key assignment only for SSH users that are `Users.writable?/2` (≥1 authorization, all
in scope; a user without authorizations is read-only until authorized in scope) — scoped writes in `Users`, `BulkOps` and `KeyAssignment` (`:scope`) return
`{:error, :out_of_scope}` otherwise; creating SSH users stays allowed. For a non-admin, the same scoped writes (`Users.create_key/3`,
`update_key/4` on a move or new key material, `BulkOps.split_user/5`, `merge_users/4`, `KeyAssignment.assign/1`
with `:role`/`:actor`) also refuse an SSH user holding a grant with admin-only options
(`Users.check_admin_only/3`, `{:error, :admin_only_options}`, fails closed without a role, audited
`admin_only_refused`). `test/ssm_web/scope_live_test.exs`
enumerates every LiveView route: a new page fails the suite until it is classified there.

**Host keys** (ADR-0008, `lib/ssm/ssh/host_key*.ex`, `lib/ssm/hosts/host_keys.ex`):
every connect verifies `host.key_fingerprint`; unpinned hosts are refused.
`Ssm.Hosts.HostKeys` (`pin/2`, `accept/3`, `pin_all/1`) is the only place that stores
keys; `probe_host_key/2` on the SSH client is the only trust-on-first-use path.

**mctl API** (`/api/mctl/v1`): `MctlContract.Plug` from the path dependency
`mctl_contract` with `SsmWeb.MctlProvider`; own `ssm_` bearer tokens, own envelope.
Conformance test: `test/ssm_web/mctl_conformance_test.exs`. `POST /hosts` runs
`SsmWeb.Mctl.CreateHostJob`: it puts `ssm_public_key` (`Ssm.Ssh.OwnKey`, derived from
`SSH_KEY`) into the still-running job's result, then retries the probe/login with backoff
(`config :ssm, :mctl_login_wait`, 10 min) until mctl has authorized that key. Host summaries (C4,
`/host-summaries`, `/hosts/{id}/summary`) read `host_checks`, which `Ssm.Diffs.SyncScheduler`
refreshes every `SSM_SYNC_INTERVAL` through `Ssm.Diffs.HostChecks.sweep/1` (disabled hosts
are never touched and keep no row; the stored drift holds fingerprints and comments only).
Contract section 10: `DELETE /hosts/{id}` (refused for a jump host in use — `jump_via` cascades)
and people (`Ssm.People` matches operator by issuer+subject, SSH users and key comments by e-mail;
`SsmWeb.Mctl.People` removes only the person's key lines per login through `script.sh`).
`probe_ssh` (contract 0.5.0, `SsmWeb.Mctl.Probe` → `Ssm.Ssh.Probe`): TCP connect + first line only, directly
or via a jump host (`ErlangClient.banner_via/4`, `ssh -W`); refused ranges, 30/min per token, audited.

**Connect Mission Control** (US-API-09, `Ssm.Mctl.Connect`, `ssm_web/live/api_tokens_live.ex`,
`/settings/api-tokens`, admin only — checked on mount and in every event): an admin creates,
rotates or revokes the UI-managed service token `mission-control` (library module
`MctlContract.Connect` on the `ssm_` token store). The token is shown once together with
`SsmWeb.Endpoint.url()` (public URL, from `PHX_HOST`) and the `MCTL_CONNECTORS_FILE` snippet;
audit actions `mctl.connect.create|rotate|revoke` (type `auth`, never the token). The
env-managed `mission-control-env` token (`Ssm.Mctl.Boot`) is separate and never touched.

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
   OTP `:crypto` deliberately — no jose/joken. Exception (approved 2026-11-06,
   ADR-0011): `oidcc` for the OIDC web login, which brings `jose` transitively; use
   jose only through oidcc, never for ssm's own JWTs.
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
10. **The Whitelist Name Gap.** Assuming this file is exempt from the secrets hook.
    `.secrets-whitelist` lists `CLAUDE.md`, but what you actually edit and stage is
    `AGENTS.md` (CLAUDE.md is just the one-line import) — and AGENTS.md is **not**
    whitelisted. *Rule: keep secret-shaped strings out of this file; reuse the exact
    example values already present in the repo when documenting.*
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

**API** (all under `/api/v2`, plural resources): `hosts` (+ `/{id}/managed-logins`, `DELETE
…/{login}`), `users`, `keys`,
`authorizations`, `activity-log`, `diffs/{host_id}` (+ `/sync`),
`auth/{login,refresh,logout,me}`, `info`. Unauthenticated health probe at
`/api/health`. Envelope: `{success, data, error{code,message,details},
meta{total,page,page_size}}`.

**Error codes** (`ssm_web/api/errors.ex`): `AUTH_REQUIRED` 401, `INVALID_CREDENTIALS`
401, `VALIDATION_FAILED` 422, `{HOST,USER,KEY,AUTHORIZATION}_NOT_FOUND` 404,
`MANAGED_LOGIN_NOT_FOUND` 404, `RATE_LIMITED` 429 (failed-login lock, `Retry-After`), `HOST_DISABLED` 409, `SSH_READONLY` 409, `CONFLICT` 409, `SSH_CONNECT_FAILED` 502,
`INTERNAL_ERROR` 500.
Diff/sync outcomes (wire changes approved 2026-11-08): unreadable listing → 502
`SSH_CONNECT_FAILED`; partial sync (root-owned `user_readonly`) or host-wide readonly → 409
`SSH_READONLY`; own key (`SSH_KEY`) unavailable → 500 `INTERNAL_ERROR`; stored key row with control
characters → 422 `VALIDATION_FAILED`. Each diff login carries an additive `notes` list
(`Ssm.Diffs.Notes`: `{kind, text, line}`, kinds `unsafe|revocation_blocked|readonly_ignored|
drops_host_restriction|invalid_stored_options|note`). Contract tests:
`test/ssm_web/api/diffs_api_test.exs`, `diff_notes_api_test.exs`.

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
`SSH_CHECK_SCHEDULE`, `SSH_UPDATE_SCHEDULE`, `SSM_SYNC_INTERVAL`, `SSM_SYNC_CONCURRENCY`, `SSM_REVOCATION_SYNC`, `JWT_SECRET` (fallback `SESSION_KEY`),
`SECRET_KEY_BASE`, `LOGLEVEL`, `PORT`, `LISTEN`, `PHX_HOST`, `PHX_ALT_HOSTS` (extra UI names, `SsmWeb.Hosts`), `POOL_SIZE`,
`TRUSTED_PROXIES`, `MCTL_TOKEN_FILE`, `MCTL_TOKEN_SCOPES`, and the OIDC set read at boot by
`Ssm.OIDC.Config` (not runtime.exs): `OIDC_ISSUER`, `OIDC_CLIENT_ID`,
`OIDC_CLIENT_SECRET_FILE`, `OIDC_ROLE_CLAIM`, `OIDC_CUSTOMERS_CLAIM`, `OIDC_GROUPS_CLAIM`
(default `orbit_groups`), `OIDC_GROUPS_DEFAULT` (only `*`, see "Operator scope"), `OIDC_ROLE_MAP`,
`OIDC_LOGIN_LABEL`, `OIDC_SESSION_MAX_HOURS`, `OIDC_RP_LOGOUT`, `LOCAL_LOGIN`.

**Secrets protection**: run `./install-hooks.sh` after cloning (installs
`.githooks/pre-commit` secret scanner; other tools may overwrite
`.git/hooks/pre-commit` — reinstall if in doubt). Server side: GitHub secret scanning +
push protection + `security-scan.yml` (TruffleHog, GitLeaks, Trivy). Legitimate test
fixtures go into `.secrets-whitelist` as `VALUE:` entries or file globs.

**Release pipeline**: tag `v*.*.*` → `release-docker.yml` builds `phoenix/Dockerfile`
for amd64+arm64, pushes to Docker Hub + GHCR with `latest`/semver manifests and
creates a GitHub release. The image applies migrations on start.

**Known open wounds** (documented so you don't re-discover them; fix only when asked):
the python-era sweeps `SSH_CHECK_SCHEDULE`/`SSH_UPDATE_SCHEDULE` are read but not wired
to jobs — restoring them needs explicit sign-off (rewrite plan §8); the read-only periodic
key check is separate (`SSM_SYNC_INTERVAL`) and never writes to a host;
`.secrets-whitelist` still carries Rust- and Python-era
path entries (harmless, narrow — cleaning it needs user approval per rule #6);
`./ssm.db` at the repo root is the final snapshot of the python stack's data, kept as
the dev-DB import source (`just import-db`). Without `getent` (busybox) `script.sh` reads `/etc/passwd` with an exact awk field match
(`ENVIRON`, no regex). Known limitations of the `script.sh`
link checks: a root-owned file an admin left in a user's home can be moved by that user to
`~/.ssh/user_readonly` and then freezes the login (the check sees a plain root-owned
file); and without `/proc` (FreeBSD/pfSense) the read side checks before it reads, so a user
who swaps `authorized_keys` for a link in the instant between check and read could still get
one read through it (Linux checks the opened file; the write side has no such window). Without
`timeout(1)` a FIFO swapped in at that instant can hang the listing until the SSH timeout.
A user who symlinks their own `~/.ssh` blocks ssm's writes, and so the revocation, for that login
on purpose: it stays a visible "revocation blocked: unsafe ~/.ssh" (diff, periodic check, audit)
that staff must resolve on the host; ssm does not repair it. On busybox (no `mv -T`/`-h`) a
symlink-to-dir planted in the instant between ssm's `rm` of the old link, its re-check and its
`mv` could still receive the root-owned 0644 temp file.

**Knowledge graph**: `.claude/settings.json` hooks keep a `code-review-graph` index
(`.code-review-graph/`, gitignored) updated on every edit. The MCP server entry was
removed with `.mcp.json` — explore with Grep/Glob/Read; if graph output surfaces
anywhere, trust files over the graph on any disagreement.

**Skills**: `verify` (run the gate), `ship` (package a correct commit), `release`
(user-invoked only). The python-era `db-migration` and `add-endpoint` skills were
removed with the python stack.

**History docs**: `docs/elixir-phoenix-rewrite.md` is the rewrite plan (historical,
kept for the record — its "SSM today" sections describe the deleted python stack).
