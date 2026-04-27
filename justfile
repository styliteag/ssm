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

# Build the backend image locally without pushing (mirrors the CI build).
docker-build:
    docker build -f backend/Dockerfile -t ssm:dev backend

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
