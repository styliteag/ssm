"""FastAPI dependencies for accessing auth services and the current user."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from ssm.auth.htpasswd import HtpasswdStore
from ssm.auth.jwt import JwtService, TokenType
from ssm.core.errors import AuthRequired

_bearer = HTTPBearer(auto_error=False)


@dataclass(frozen=True, slots=True)
class CurrentUser:
    username: str


def get_jwt_service(request: Request) -> JwtService:
    svc = getattr(request.app.state, "jwt_service", None)
    if not isinstance(svc, JwtService):
        msg = "JwtService not configured on app.state"
        raise RuntimeError(msg)
    return svc


def get_htpasswd_store(request: Request) -> HtpasswdStore:
    store = getattr(request.app.state, "htpasswd_store", None)
    if not isinstance(store, HtpasswdStore):
        msg = "HtpasswdStore not configured on app.state"
        raise RuntimeError(msg)
    return store


def get_current_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
    jwt_service: Annotated[JwtService, Depends(get_jwt_service)],
) -> CurrentUser:
    if credentials is None or not credentials.credentials:
        raise AuthRequired
    claims = jwt_service.verify(credentials.credentials, expected_type=TokenType.ACCESS)
    return CurrentUser(username=claims.sub)
