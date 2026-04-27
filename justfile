# https://github.com/casey/just
set shell := ["bash", "-cu"]

default:
    @just --list

# --- Setup -----------------------------------------------------------------

install: backend-install frontend-install

# --- Backend ---------------------------------------------------------------

backend-install:
    cd backend && uv sync

backend-run:
    cd backend && uv run uvicorn ssm.main:app --reload --host 0.0.0.0 --port 8000

backend-test *args:
    cd backend && uv run pytest -q {{args}}

backend-test-cov:
    cd backend && uv run pytest --cov=ssm --cov-report=term-missing -q

backend-lint:
    cd backend && uv run ruff check src tests

backend-fmt:
    cd backend && uv run ruff format src tests

backend-typecheck:
    cd backend && uv run mypy src

backend-security:
    cd backend && uv run bandit -r src -q

# --- Frontend --------------------------------------------------------------

frontend-install:
    cd frontend && npm install

frontend-dev:
    cd frontend && npm run dev

frontend-build:
    cd frontend && npm run build

frontend-build-prod:
    cd frontend && npm run build:prod

frontend-preview:
    cd frontend && npm run preview

frontend-lint:
    cd frontend && npm run lint

frontend-typecheck:
    cd frontend && npm run type-check

# --- Aggregates ------------------------------------------------------------

# Run every quality gate (matches the /verify skill).
verify: backend-lint backend-typecheck backend-security backend-test frontend-lint frontend-typecheck

# Format both stacks (frontend has no formatter wired; ruff handles backend).
fmt: backend-fmt

# --- Database / Migrations -------------------------------------------------

migrate:
    cd backend && uv run alembic upgrade head

migrate-new name:
    cd backend && uv run alembic revision --autogenerate -m "{{name}}"

migrate-history:
    cd backend && uv run alembic history --verbose

migrate-down:
    cd backend && uv run alembic downgrade -1

# One-shot copy from a Rust-Diesel SQLite DB into a freshly-Alembic-migrated DB.
# Usage: just migrate-from-rust ../path/to/old.db
migrate-from-rust source dest="./ssm.db":
    cd backend && uv run python scripts/migrate_from_rust.py --source {{source}} --dest {{dest}}

# --- Dev environment -------------------------------------------------------

dev:
    ./start-dev.sh

# --- Stack (production) ----------------------------------------------------

up:
    docker compose -f docker/compose.prod.yml up -d --build

down:
    docker compose -f docker/compose.prod.yml down

logs:
    docker compose -f docker/compose.prod.yml logs -f --tail=200

ps:
    docker compose -f docker/compose.prod.yml ps

# Build the combined production image locally (mirrors the CI build).
# Includes built frontend, FastAPI backend, and nginx — all in one image.
docker-build:
    docker build -f docker/app/Dockerfile -t ssm:dev .

# Run the combined image locally on http://localhost:8080.
# Uses a scratch data dir under /tmp so it doesn't touch your real ./docker/data.
# Volumes (db/config/keys/logs) are created on first run.
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
        -e HTPASSWD=config/.htpasswd \
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

# Drop venvs, build artifacts, caches. Leaves DBs and config alone.
clean:
    rm -rf backend/.venv backend/.pytest_cache backend/.mypy_cache backend/.ruff_cache backend/htmlcov backend/.coverage*
    rm -rf frontend/node_modules frontend/dist
