"""FastAPI application factory."""

from __future__ import annotations

import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass

from apscheduler.schedulers.asyncio import AsyncIOScheduler
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ssm.api.v2 import v2_router
from ssm.auth.htpasswd import HtpasswdStore
from ssm.auth.jwt import JwtService
from ssm.core.exception_handlers import install_exception_handlers
from ssm.ssh.protocol import SshClient

_DEFAULT_DEV_ORIGINS = ("http://localhost:5173", "http://127.0.0.1:5173")


@dataclass(frozen=True, slots=True)
class AppDependencies:
    htpasswd_store: HtpasswdStore
    jwt_service: JwtService
    sessionmaker: async_sessionmaker[AsyncSession] | None = None
    ssh_client: SshClient | None = None
    scheduler: AsyncIOScheduler | None = None


def _cors_origins() -> list[str]:
    """Comma-separated ``CORS_ORIGINS`` env, or the dev default (Vite)."""
    raw = os.environ.get("CORS_ORIGINS", "").strip()
    if not raw:
        return list(_DEFAULT_DEV_ORIGINS)
    return [origin.strip() for origin in raw.split(",") if origin.strip()]


def create_app(deps: AppDependencies) -> FastAPI:
    """Build a FastAPI app with the given auth + DB dependencies wired up."""

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        if deps.scheduler is not None and not deps.scheduler.running:
            deps.scheduler.start(paused=False)
        try:
            yield
        finally:
            if deps.scheduler is not None and deps.scheduler.running:
                deps.scheduler.shutdown(wait=False)

    app = FastAPI(
        title="ssm",
        version="2.0.0",
        docs_url="/api/v2/docs",
        openapi_url="/api/v2/openapi.json",
        lifespan=lifespan,
    )
    app.state.htpasswd_store = deps.htpasswd_store
    app.state.jwt_service = deps.jwt_service
    app.state.sessionmaker = deps.sessionmaker
    app.state.ssh_client = deps.ssh_client
    app.state.scheduler = deps.scheduler

    # CORS — middleware must be added before the router so preflight works.
    app.add_middleware(
        CORSMiddleware,
        allow_origins=_cors_origins(),
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    install_exception_handlers(app)
    app.include_router(v2_router)
    return app
