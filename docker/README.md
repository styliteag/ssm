# Secure SSH Manager — Docker

Single all-in-one image: an Elixir/Phoenix release serves the LiveView UI and the `/api/v2` JSON API on port 80. Database migrations run automatically on startup — the ecto baseline migration adopts databases created by the earlier Diesel (Rust) and Alembic (Python) stacks in place, so existing data volumes keep working unchanged.

## Quick start

```bash
mkdir -p data/{db,config,keys,logs}

# Required: signing secret (32+ chars) for API tokens + session cookies.
echo "JWT_SECRET=$(openssl rand -hex 32)" > .env

# Authentication file — password is bcrypt-hashed.
htpasswd -cB data/config/.htpasswd admin

# SSH key the server uses to connect to managed hosts.
ssh-keygen -t ed25519 -f data/keys/id_ssm -C ssm-server -N ''

docker compose up -d --build
```

Access the UI at `http://localhost/`.

## Image layout

Multi-stage build (`phoenix/Dockerfile`, build context = repository root):

1. **builder** — `elixir:1.20`, fetches locked deps, compiles, builds assets (`mix assets.deploy`), and assembles a `mix release`.
2. **runtime** — `debian:trixie-slim` + `openssh-client` (jump-host chains, boot-time key decryption) + tini. `start.sh` fixes bind-mount ownership, runs `/app/bin/migrate`, then execs the release on port 80.

## Volumes

| Host path | Container path | Purpose |
|---|---|---|
| `./data/db` | `/app/db` | SQLite database (`ssm.db`) |
| `./data/config` | `/app/config` | `.htpasswd` (auth) |
| `./data/keys` | `/app/keys` | SSH private key (`id_ssm`) |
| `./data/logs` | `/app/logs` | Logs (optional) |

These are the same host paths and container paths as the previous python/react image — no data migration needed.

## Environment

| Variable | Default | Notes |
|---|---|---|
| `JWT_SECRET` | — | **Required**, 32+ random chars. `SESSION_KEY` is accepted as alias. Signs API bearer tokens and derives the session cookie secret. |
| `SECRET_KEY_BASE` | derived from `JWT_SECRET` | Optional explicit Phoenix secret (64+ bytes). |
| `DATABASE_URL` | `sqlite:///ssm.db` | Note: 4 slashes = absolute path. `DATABASE_PATH` (plain path) wins when set. |
| `HTPASSWD` | `.htpasswd` | Relative paths resolve under `/app`. |
| `SSH_KEY` | `keys/id_ssm` | Server's private key for connecting to managed hosts. |
| `SSH_KEY_PASSPHRASE` | — | Decrypts an encrypted key at boot (`ssh-keygen -p` into a temp copy). |
| `SSH_TIMEOUT` | `120` | Seconds budget for exec/sftp operations. |
| `SSH_CONNECT_TIMEOUT` | `10` | Seconds budget for TCP+handshake per connect. |
| `SSH_CONCURRENCY` | `32` | Parallel host checks in the diff viewer status sweep. |
| `LOGLEVEL` | `info` | Accepts RUST_LOG-style directives; most verbose level wins. |
| `PORT` / `LISTEN` | `80` / `::` | Listen port and interface. |

## Health checks

`/app/bin/health-check.sh` probes the unauthenticated `/api/health` endpoint (version + database check).

## CI

Tag pushes (`v*.*.*`) trigger `.github/workflows/release-docker.yml`, which builds `phoenix/Dockerfile` for `linux/amd64` + `linux/arm64`, publishes per-arch tags, and assembles multi-arch manifests at:

- `ghcr.io/styliteag/ssm/ssm:<version>` and `:latest`
- `styliteag/ssm:<version>` and `:latest`

## Troubleshooting

- **Port 80 already in use** — change the host-side mapping: `ports: ["8080:80"]`.
- **Editing `.htpasswd`** — the file is read per login attempt; new users and password changes take effect immediately, no restart needed.
- **Inspect runtime files** — `docker compose exec ssm sh` then look at `/app/db/`, `/app/config/`, `/app/keys/`.
- **Database browser** — `docker compose -f docker-compose.adminer.yml up` serves sqlite-web on `:8080` (read-only mount of `data/db/ssm.db`).
