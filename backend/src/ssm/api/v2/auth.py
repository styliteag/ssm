"""Auth routes: ``/api/v2/auth/{login,refresh,logout,me}``."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from ssm.auth.deps import (
    CurrentUser,
    get_current_user,
    get_htpasswd_store,
    get_jwt_service,
)
from ssm.auth.htpasswd import HtpasswdStore
from ssm.auth.jwt import JwtService, TokenType
from ssm.core.envelope import ApiResponse
from ssm.core.errors import InvalidCredentials

router = APIRouter(prefix="/auth", tags=["auth"])


class LoginRequest(BaseModel):
    username: str = Field(min_length=1, max_length=128)
    password: str = Field(min_length=1, max_length=1024)


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=1)


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "Bearer"  # noqa: S105


class MeResponse(BaseModel):
    username: str


class LogoutResponse(BaseModel):
    logged_out: bool


def _issue_pair(jwt_service: JwtService, subject: str) -> TokenPair:
    return TokenPair(
        access_token=jwt_service.issue_access(subject),
        refresh_token=jwt_service.issue_refresh(subject),
    )


@router.post("/login", response_model=ApiResponse[TokenPair])
def login(
    payload: LoginRequest,
    htpasswd: Annotated[HtpasswdStore, Depends(get_htpasswd_store)],
    jwt_service: Annotated[JwtService, Depends(get_jwt_service)],
) -> ApiResponse[TokenPair]:
    if not htpasswd.verify(payload.username, payload.password):
        raise InvalidCredentials
    return ApiResponse[TokenPair].ok(_issue_pair(jwt_service, payload.username))


@router.post("/refresh", response_model=ApiResponse[TokenPair])
def refresh(
    payload: RefreshRequest,
    jwt_service: Annotated[JwtService, Depends(get_jwt_service)],
) -> ApiResponse[TokenPair]:
    claims = jwt_service.verify(payload.refresh_token, expected_type=TokenType.REFRESH)
    return ApiResponse[TokenPair].ok(_issue_pair(jwt_service, claims.sub))


@router.post("/logout", response_model=ApiResponse[LogoutResponse])
def logout() -> ApiResponse[LogoutResponse]:
    # Stateless JWT: client discards tokens. A future revocation list can plug in here.
    return ApiResponse[LogoutResponse].ok(LogoutResponse(logged_out=True))


@router.get("/me", response_model=ApiResponse[MeResponse])
def me(user: Annotated[CurrentUser, Depends(get_current_user)]) -> ApiResponse[MeResponse]:
    return ApiResponse[MeResponse].ok(MeResponse(username=user.username))
