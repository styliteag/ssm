# Upgrading a production deployment to the Elixir image

Applies to any deployment running the old Python/React image
(`ghcr.io/styliteag/ssm/ssm:1.1.x`) — including compose setups behind a
reverse proxy such as Traefik. The Elixir image was built for a drop-in
switch: same port, same volume paths, same environment variables, same
database file.

## TL;DR

Change the image tag. Everything else keeps working.

```yaml
services:
  ssm:
    # before
    # image: ghcr.io/styliteag/ssm/ssm:1.1.11
    # after (first Elixir release — check the releases page for the actual number)
    image: ghcr.io/styliteag/ssm/ssm:2.0.0
```

Then:

```bash
# 1. Backup the database first (transaction-safe, source untouched)
sqlite3 ./data/db/ssm.db ".backup './data/db/ssm.db.pre-elixir'"

# 2. Pull + restart
docker compose pull && docker compose up -d
```

On first boot the Elixir release runs its baseline migration, which **adopts
the existing database in place** — it detects the Alembic-era schema, fills
only what is missing, and stamps its own migration table. Your data is not
copied, converted, or dropped.

## What stays exactly the same

| Concern | Detail |
|---|---|
| Port | The container serves everything on `:80` — Traefik's `loadbalancer.server.port=80` label is unchanged. |
| Volumes | `./data/db:/app/db`, `./data/config:/app/config`, `./data/keys:/app/keys`, `./data/logs:/app/logs` — identical mount contract. |
| `DATABASE_URL` | `sqlite:///db/ssm.db` (and the old `sqlite+aiosqlite:///...` form) are both understood; relative paths resolve under `/app` as before. |
| `HTPASSWD` | `config/.htpasswd` resolves to `/app/config/.htpasswd` as before. Same bcrypt htpasswd file, same users. |
| `SESSION_KEY` / `JWT_SECRET` | Both names accepted, same fallback order as the Python stack. The same secret keeps signing API tokens, so **existing API clients and their tokens keep working across the switch**. |
| `SSH_KEY` | Default `keys/id_ssm` → `/app/keys/id_ssm`, unchanged. Encrypted keys: set `SSH_KEY_PASSPHRASE` as before. |
| API | `/api/v2` is wire-compatible: same endpoints, envelope, field names, and error codes. |
| Health check | Built into the image (probes `/api/health`); a compose-level healthcheck is not required. |

## What to clean up in the compose file (optional)

- `CONFIG=config/config.toml` (commented in most setups): dead since the
  Rust era — there is no config file at all, configuration is env-only.
  Delete the line.
- `RUST_LOG`: not read as a variable name. Use `LOGLEVEL` instead — it
  accepts the same directive syntax (`info`, `ssm=debug,actix=warn`), the
  most verbose level wins.
- `SESSION_KEY` → consider renaming to `JWT_SECRET` (the primary name);
  purely cosmetic, both work. Keep the **same value** — changing it logs out
  API clients.

## Behind Traefik / a reverse proxy

The UI is now server-rendered (Phoenix LiveView) and uses a **WebSocket**
connection per browser tab. Traefik proxies WebSocket upgrades out of the
box — no extra middleware or label needed. The app validates the WebSocket
origin against the request's own `Host` header, so it works under any
hostname without setting `PHX_HOST`.

TLS termination stays at the proxy; the container speaks plain HTTP on `:80`
exactly like the old image.

## Behavior changes you will notice

- **Web login sessions last 7 days.** The old frontend silently logged you
  out after 15 minutes (its token refresh was broken). The UI now uses
  session cookies; a password change or user removal invalidates that user's
  sessions on their next request.
- **The UI is LiveView** — same seven pages, plus list/card toggles, sortable
  columns, a theme picker, and a faster diff viewer with cached host
  statuses.
- **First start after the upgrade** logs `Running database migrations...`
  once while the baseline adopts the database. Subsequent starts are
  instant.

## Rollback

The adoption is non-destructive: the Alembic version table is left in place
and the schema is unchanged, so rolling back is just reverting the image tag
to `1.1.x` and `docker compose up -d`. The `.pre-elixir` backup from the
TL;DR is the belt-and-suspenders on top of that.

## Not carried over

- The scheduled check/update sweeps (`SSH_CHECK_SCHEDULE`,
  `SSH_UPDATE_SCHEDULE`) were never functional in the Python stack (the
  variables were read but no jobs ran). The Elixir stack reads them too but
  deliberately does not schedule anything yet — restoring the documented
  behavior is tracked separately.
- `DOTENV` (python-dotenv file loading): not supported. Put configuration in
  the compose `environment:` block.
