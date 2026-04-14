# syntax=docker/dockerfile:1.7

# ---- build stage: resolve venv with uv --------------------------------------
FROM python:3.12-slim-bookworm AS build

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Install uv from its official distroless image — avoids curl pipes.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

WORKDIR /app

# Install only dependencies first for better layer caching.
COPY pyproject.toml uv.lock README.md ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

# Now add the application source and install the project itself.
COPY src ./src
COPY migrations ./migrations
COPY alembic.ini ./alembic.ini
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev


# ---- runtime stage: slim, non-root ------------------------------------------
FROM python:3.12-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/app/.venv/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 1000 ssm \
    && useradd  --system --uid 1000 --gid 1000 --home-dir /app --shell /usr/sbin/nologin ssm

WORKDIR /app

COPY --from=build --chown=ssm:ssm /app/.venv /app/.venv
COPY --chown=ssm:ssm src ./src
COPY --chown=ssm:ssm migrations ./migrations
COPY --chown=ssm:ssm alembic.ini ./alembic.ini
COPY --chown=ssm:ssm pyproject.toml uv.lock README.md ./

USER ssm
EXPOSE 8000

ENTRYPOINT ["tini", "--"]
CMD ["uvicorn", "ssm.main:app", "--host", "0.0.0.0", "--port", "8000"]
