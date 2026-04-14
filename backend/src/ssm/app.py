"""FastAPI application factory."""

from __future__ import annotations

from dataclasses import dataclass

from fastapi import FastAPI

from ssm.api.v2 import v2_router
from ssm.auth.htpasswd import HtpasswdStore
from ssm.auth.jwt import JwtService
from ssm.core.exception_handlers import install_exception_handlers


@dataclass(frozen=True, slots=True)
class AppDependencies:
    htpasswd_store: HtpasswdStore
    jwt_service: JwtService


def create_app(deps: AppDependencies) -> FastAPI:
    """Build a FastAPI app with the given auth dependencies wired up."""
    app = FastAPI(
        title="ssm", version="2.0.0", docs_url="/api/v2/docs", openapi_url="/api/v2/openapi.json"
    )
    app.state.htpasswd_store = deps.htpasswd_store
    app.state.jwt_service = deps.jwt_service

    install_exception_handlers(app)
    app.include_router(v2_router)
    return app
