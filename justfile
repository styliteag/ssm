# https://github.com/casey/just
set shell := ["bash", "-cu"]

default:
    @just --list

# --- Elixir (phoenix/, docker-only toolchain) -------------------------------

# Run a mix task inside the dev container (no local Elixir needed).
mix *args:
    cd phoenix && docker compose run --rm app sh -c "mix local.hex --force >/dev/null 2>&1 && mix local.rebar --force >/dev/null 2>&1 && mix {{args}}"

test *args:
    @just mix test {{args}}

format:
    @just mix format

# compile --warnings-as-errors + format --check-formatted + test
verify:
    @just mix precommit

# --- Dev environment --------------------------------------------------------

# Dev server on http://localhost:4000.
dev: _maybe-import-db
    cd phoenix && docker compose up

dev-detached: _maybe-import-db
    cd phoenix && docker compose up -d

dev-down:
    cd phoenix && docker compose down

# --- Database ----------------------------------------------------------------

# Snapshot the legacy python-stack DB (./ssm.db) into the elixir dev DB.
# sqlite3 .backup is transaction-safe and only reads the source; the ecto
# baseline migration adopts the snapshot (fills gaps, stamps) on next boot.
import-db:
    sqlite3 ssm.db ".backup 'phoenix/ssm_dev.db'"
    rm -f phoenix/ssm_dev.db-shm phoenix/ssm_dev.db-wal
    @echo "Imported ssm.db -> phoenix/ssm_dev.db ($(sqlite3 phoenix/ssm_dev.db 'select count(*) from host') hosts)"

# Import automatically when the dev DB has no data yet but ./ssm.db does.
_maybe-import-db:
    #!/usr/bin/env bash
    set -u
    if [ -s ssm.db ]; then
      hosts=$(sqlite3 phoenix/ssm_dev.db "select count(*) from host" 2>/dev/null || echo 0)
      if [ "${hosts:-0}" = "0" ]; then just import-db; fi
    fi

# --- Stack (production) ------------------------------------------------------

up:
    docker compose -f docker/compose.yml up -d --build

down:
    docker compose -f docker/compose.yml down

logs:
    docker compose -f docker/compose.yml logs -f --tail=200

ps:
    docker compose -f docker/compose.yml ps

# Build the production image locally (mirrors the CI build).
docker-build:
    docker build -f phoenix/Dockerfile -t ssm:dev \
        --build-arg VERSION=$(cat VERSION) \
        --build-arg VCS_REF=$(git rev-parse HEAD) .

# Run the locally built image on http://localhost:8080.
# Uses a scratch data dir under /tmp so it doesn't touch your real ./docker/data.
docker-run: docker-build
    @mkdir -p /tmp/ssm-dev/data/db /tmp/ssm-dev/data/config /tmp/ssm-dev/data/keys /tmp/ssm-dev/data/logs
    docker rm -f ssm-dev 2>/dev/null || true
    docker run -d --name ssm-dev \
        -p 8080:80 \
        -v /tmp/ssm-dev/data/db:/app/db \
        -v /tmp/ssm-dev/data/config:/app/config \
        -v /tmp/ssm-dev/data/keys:/app/keys \
        -v /tmp/ssm-dev/data/logs:/app/logs \
        -e DATABASE_URL=sqlite:////app/db/ssm.db \
        -e HTPASSWD=/app/config/.htpasswd \
        -e JWT_SECRET=dev-secret-change-me-dev-secret-change-me \
        -e LOGLEVEL=debug \
        ssm:dev
    @echo "→ http://localhost:8080  (logs: just docker-logs)"

docker-logs:
    docker logs -f ssm-dev

docker-stop:
    docker rm -f ssm-dev 2>/dev/null || true

# --- Release ----------------------------------------------------------------

# Bump version, update CHANGELOG.md, tag, push. CI builds + publishes image.
# Usage: just release patch|minor|major
release type="patch":
    ./release.sh {{type}}

# --- Cleanup ---------------------------------------------------------------

# Drop build caches. Leaves DBs, keys, and config alone.
clean:
    rm -rf phoenix/data/build phoenix/data/deps phoenix/data/toolchain
