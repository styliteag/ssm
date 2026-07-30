# Secure SSH Manager (SSM)

> [!NOTE]
> This is pre-release software. Use at your own risk.

A web application for managing SSH `authorized_keys` files across multiple hosts — Elixir/Phoenix LiveView with a wire-compatible `/api/v2` JSON API.

## Prerequisites

- **Docker** — the entire toolchain runs in containers; no local Elixir needed
- **just** — `brew install just` (or any installer from https://github.com/casey/just#installation)
- **sqlite3** CLI (ships with macOS) — used by the dev DB import helper

## Quick Start

```bash
just dev          # dev server (docker compose) on http://localhost:4000
```

If a legacy `./ssm.db` snapshot exists and the dev database is empty, it is imported automatically on first start.

Run `just` to see all available commands.

## Architecture

| Layer | Stack |
|---|---|
| Web UI | Phoenix LiveView (server-rendered, four switchable themes) |
| API | `/api/v2` JSON API — JWT bearer auth, envelope + stable error codes |
| Runtime | Elixir 1.20 / OTP, single `mix release` |
| Database | SQLite via `ecto_sqlite3` |
| Migrations | Ecto — the baseline migration adopts Diesel-/Alembic-era databases in place |
| Auth | htpasswd credential store (bcrypt) — session cookies for the UI, JWT (HS256) for the API |
| SSH | Erlang `:ssh` + `openssh-client` for jump-host chains and encrypted-key decryption |

The production Docker image (`phoenix/Dockerfile`) is a single container serving everything on port 80. Migrations run automatically on startup.

## Development Workflow

```bash
just dev            # dev server on :4000 (live reload)
just test           # ExUnit suite (includes /api/v2 contract tests)
just format         # mix format
just verify         # compile --warnings-as-errors + format check + tests
just mix <task>     # any mix task inside the dev container
```

## Configuration

Every setting is read from environment variables (see `phoenix/config/runtime.exs`). Names and defaults mirror the previous python stack, so existing deployments switch without touching their environment.

| Variable | Default | Description |
|---|---|---|
| `DATABASE_URL` | `sqlite:///ssm.db` | `sqlite:///relative.db` or `sqlite:////abs/path.db`; `DATABASE_PATH` (plain path) wins when set |
| `JWT_SECRET` | — | Required in production (32+ chars); signs API tokens, derives the cookie secret. `SESSION_KEY` accepted as alias |
| `SECRET_KEY_BASE` | derived | Optional explicit Phoenix secret (64+ bytes) |
| `HTPASSWD` | `.htpasswd` | Path to htpasswd credential file |
| `SSH_KEY` | `keys/id_ssm` | Path to SSH private key |
| `SSH_KEY_PASSPHRASE` | — | Passphrase if the SSH key is encrypted (decrypted at boot) |
| `SSH_TIMEOUT` | `120` | Exec/sftp budget in seconds |
| `SSH_CONNECT_TIMEOUT` | `10` | TCP+handshake budget per connect |
| `SSH_CONCURRENCY` | `32` | Parallel host checks in the diff viewer |
| `LOGLEVEL` | `info` | Accepts RUST_LOG-style directives; most verbose wins |
| `PORT` | `8000` (image: `80`) | Listen port |
| `LISTEN` | `::` | Listen address |

### SSH Key

Generate a key for the server to use when connecting to managed hosts:

```bash
ssh-keygen -t ed25519 -f phoenix/keys/id_ssm -C 'ssm-server' -N ''
```

The dev container mounts `phoenix/keys/` read-only at `/app/keys`.

### Authentication

```bash
htpasswd -cB phoenix/.htpasswd admin    # create file
htpasswd -B phoenix/.htpasswd user2     # add user
```

The file is read per login attempt — changes take effect immediately.

## Production Deployment

The combined image (`ghcr.io/styliteag/ssm/ssm:latest`) serves everything on port 80.

```bash
just up      # docker compose -f docker/compose.yml up -d --build
just down    # tear down
just logs    # tail logs
```

The compose file (`docker/compose.yml`) expects persistent volumes at `docker/data/` — the same layout (and data) the previous python/react image used:

```
docker/data/
├── config/.htpasswd      # credentials
├── keys/id_ssm           # SSH private key
├── db/                   # SQLite database
└── logs/                 # logs (optional)
```

`JWT_SECRET` must be set — uncomment the line in `compose.yml` and supply a 32+ character value.

See [docker/README.md](docker/README.md) for details.

### Local combined-image dev run

To exercise the production image locally on `http://localhost:8080` without affecting prod data:

```bash
just docker-build     # build phoenix/Dockerfile
just docker-run       # run it on :8080 with a scratch data dir under /tmp
just docker-stop      # tear it down
```

## Release

```bash
just release          # patch bump
just release minor    # minor bump
just release major    # major bump
```

Bumps `VERSION`, commits, tags, and pushes. The tag push triggers the CI build.

## SSH Management Controls

- **Disabled hosts**: mark a host as disabled in the UI to skip all SSH operations (maintenance, decommission)
- **`.ssh/system_readonly`** on a remote host: prevents SSM from modifying any keyfile
- **`.ssh/user_readonly`** on a remote host: prevents modifications for a specific user

Both files accept an optional reason string that is displayed in the UI.

## Security Features

- All `/api/v2` endpoints require a valid JWT Bearer token (except `/api/v2/auth/login` and `/api/health`)
- Passwords stored as bcrypt hashes in htpasswd format
- JWT tokens signed with HS256; access and refresh tokens are distinct types (not interchangeable)
- SSH connections use key-based authentication only

## License

Secure SSH Manager (SSM) is **source-available** under the **Business Source
License 1.1 (BSL 1.1)**. You may read, build, modify, and run it for your own
organization for free; offering it as a hosted/managed service or
reselling it for a fee needs a commercial license from STYLiTE. Each released
version converts to **GPL v3.0 or later** four years after publication.

See [LICENSE](LICENSE) for the full legal text and [LICENSING.md](LICENSING.md)
for a plain-language summary. For commercial / hosting licenses, contact
office@stylite.de.
