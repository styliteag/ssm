# syntax=docker/dockerfile:1.7
#
# Combined image: React frontend (built with Vite, served by nginx) +
# FastAPI backend (uvicorn behind nginx). Single container, port 80.
#
# Build context is the repository root (so both frontend/ and backend/ are
# visible). See .github/workflows/release-docker.yml.

# ---- frontend builder -------------------------------------------------------
FROM node:24-alpine AS frontend-builder

ARG VITE_API_URL=/api/v2
WORKDIR /src

COPY frontend/package*.json ./
RUN npm ci --no-audit --no-fund

COPY frontend/. .
COPY VERSION /VERSION
ENV VITE_API_URL=${VITE_API_URL}
ENV VITE_APP_VERSION_FILE=/VERSION
RUN VITE_APP_VERSION="$(cat /VERSION)" npm run build


# ---- backend builder (resolve venv with uv) ---------------------------------
FROM python:3.12-slim-bookworm AS backend-builder

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

WORKDIR /app

# Dependencies first for layer caching.
COPY backend/pyproject.toml backend/uv.lock backend/README.md ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-project --no-dev

# Project source.
COPY backend/src ./src
COPY backend/migrations ./migrations
COPY backend/alembic.ini ./alembic.ini
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev


# ---- runtime: nginx + uvicorn -----------------------------------------------
FROM python:3.12-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH=/app/.venv/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx tini ca-certificates wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Backend venv + source from backend-builder.
COPY --from=backend-builder /app/.venv /app/.venv
COPY --from=backend-builder /app/src /app/src
COPY --from=backend-builder /app/migrations /app/migrations
COPY --from=backend-builder /app/alembic.ini /app/alembic.ini

# Frontend build → nginx document root.
COPY --from=frontend-builder /src/dist /usr/share/nginx/html

# nginx + entrypoint scripts.
COPY docker/app/nginx-main.conf /etc/nginx/nginx.conf
COPY docker/app/start.sh /app/start.sh
COPY docker/app/health-check.sh /app/health-check.sh
COPY VERSION /app/VERSION

# Third-party license attribution + SBOM must travel with the distributed image.
COPY THIRD-PARTY-LICENSES.md /app/THIRD-PARTY-LICENSES.md
COPY LICENSE /app/LICENSE
COPY sbom /app/sbom

RUN mkdir -p /app/db /app/keys /app/config /app/logs \
    && chmod +x /app/start.sh /app/health-check.sh

EXPOSE 80

ARG VERSION
ARG VCS_REF
LABEL org.opencontainers.image.title="ssm" \
      org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$VCS_REF \
      org.opencontainers.image.source="https://github.com/styliteag/ssm"

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD /app/health-check.sh || exit 1

ENTRYPOINT ["tini", "--"]
CMD ["/app/start.sh"]
