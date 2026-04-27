# SSH Key Manager — Docker

Single all-in-one image: nginx serves the React SPA on port 80 and reverse-proxies `/api/*` to a FastAPI backend running on `127.0.0.1:8000` inside the same container. Database migrations run automatically on startup.

## Quick start

```bash
mkdir -p data/{db,config,keys,logs}

# Required: JWT signing secret (32+ chars).
echo "JWT_SECRET=$(openssl rand -hex 32)" > .env

# Authentication file — password is bcrypt-hashed.
htpasswd -cB data/config/.htpasswd admin

# SSH key the server uses to connect to managed hosts.
ssh-keygen -t ed25519 -f data/keys/id_ssm -C ssm-server -N ''

docker compose -f compose.prod.yml up -d --build
```

Access the UI at `http://localhost/`.

## Image layout

Multi-stage build (`docker/app/Dockerfile`):

1. **frontend-builder** — `node:24-alpine`, runs `npm ci && npm run build` to produce `frontend/dist/`.
2. **backend-builder** — `python:3.12-slim` with [`uv`](https://docs.astral.sh/uv/), resolves the locked venv from `backend/pyproject.toml` + `backend/uv.lock`.
3. **runtime** — `python:3.12-slim` + nginx + tini. Frontend assets land at `/usr/share/nginx/html`, the venv at `/app/.venv`, source at `/app/src`. `start.sh` runs `alembic upgrade head` then launches uvicorn (loopback) and nginx (port 80) under tini.

## Volumes

| Host path | Container path | Purpose |
|---|---|---|
| `./data/db` | `/app/db` | SQLite database (`ssm.db`) |
| `./data/config` | `/app/config` | `config.toml` (optional), `.htpasswd` |
| `./data/keys` | `/app/keys` | SSH private key (`id_ssm`) |
| `./data/logs` | `/app/logs` | App logs (optional) |

## Environment

| Variable | Default | Notes |
|---|---|---|
| `JWT_SECRET` | — | **Required**, 32+ random chars. `SESSION_KEY` is accepted as alias. |
| `DATABASE_URL` | `sqlite:////app/db/ssm.db` | Note: 4 slashes = absolute path. |
| `HTPASSWD` | `config/.htpasswd` | Relative paths resolve under `/app`. |
| `SSH_KEY` | `keys/id_ssm` | Server's private key for connecting to managed hosts. |
| `LOGLEVEL` | `info` | `debug`, `info`, `warning`, `error`. |
| `CONFIG` | (unset) | Optional path to a `config.toml`. |

## Health checks

`/app/health-check.sh` verifies nginx (port 80) and uvicorn (port 8000 internal) both respond.

## Routing

nginx routes inside the container:

| Path | Target |
|---|---|
| `/` | SPA (`/usr/share/nginx/html`, with `try_files … /index.html` fallback for client-side routes) |
| `/api/v2/auth/*` | uvicorn, with strict rate limit (login zone) |
| `/api/v2/(hosts\|diffs)/.*(logins\|sync\|...)` | uvicorn, longer read timeout for SSH ops |
| `/api/*` | uvicorn (catch-all) |

## CI

Tag pushes (`v*.*.*`) trigger `.github/workflows/release-docker.yml`, which builds this Dockerfile for `linux/amd64` + `linux/arm64`, publishes per-arch tags, and assembles multi-arch manifests at:

- `ghcr.io/styliteag/ssm/ssm:<version>` and `:latest`
- `styliteag/ssm:<version>` and `:latest`

## Troubleshooting

- **Port 80 already in use** — change the host-side mapping: `ports: ["8080:80"]`.
- **First-run permission errors on Linux** — the image runs as root, so bind-mounted `data/` directories don't need a uid match. If you previously deployed the backend-only image (which ran as uid 1000), `chown -R root:root data/` once.
- **Login fails after editing `.htpasswd`** — the htpasswd store loads at startup; restart the container to pick up new entries: `docker compose restart`.
- **Inspect runtime files** — `docker compose exec ssm sh` then look at `/app/db/`, `/app/config/`, `/app/keys/`.
