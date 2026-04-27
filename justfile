# https://github.com/casey/just
set shell := ["bash", "-cu"]

default:
    @just --list

# --- Backend ---------------------------------------------------------------

backend-install:
    cd backend && uv sync --all-extras

backend-run:
    cd backend && uv run uvicorn ssm.main:app --reload --host 0.0.0.0 --port 8000

backend-test:
    cd backend && uv run pytest -q

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

frontend-lint:
    cd frontend && npm run lint

frontend-typecheck:
    cd frontend && npm run type-check

# --- Database / Migrations -------------------------------------------------

migrate:
    cd backend && uv run alembic upgrade head

migrate-new name:
    cd backend && uv run alembic revision --autogenerate -m "{{name}}"

migrate-history:
    cd backend && uv run alembic history --verbose

migrate-down:
    cd backend && uv run alembic downgrade -1

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

# --- Release ----------------------------------------------------------------

# Bump version, update CHANGELOG.md, tag, push. CI builds + publishes image.
# Usage: just release patch|minor|major
release type="patch":
    ./release.sh {{type}}
