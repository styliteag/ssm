# ssm backend (Python/FastAPI)

Rewrite of the Rust/Actix backend. See `../plans/python-backend-rewrite.md`.

## Quickstart

```bash
uv sync
uv run pytest
uv run ruff check
uv run ruff format --check
uv run mypy --strict src
uv run bandit -r src
```
