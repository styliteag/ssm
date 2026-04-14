"""``/api/v2/authorizations`` — user↔host links with per-host remote login."""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ssm.auth.deps import protected_router
from ssm.core.envelope import ApiResponse, Meta
from ssm.core.errors import AuthorizationNotFound, Conflict, HostNotFound, UserNotFound
from ssm.db.deps import db_session
from ssm.db.models import Authorization, Host, User

router = protected_router(prefix="/authorizations", tags=["authorizations"])


class AuthorizationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    host_id: int
    user_id: int
    login: str
    options: str | None = None
    comment: str | None = None


class CreateAuthorizationRequest(BaseModel):
    host_id: int
    user_id: int
    login: str = Field(min_length=1, max_length=128)
    options: str | None = Field(default=None, max_length=1024)
    comment: str | None = Field(default=None, max_length=1024)


class UpdateAuthorizationRequest(BaseModel):
    login: str | None = Field(default=None, min_length=1, max_length=128)
    options: str | None = Field(default=None, max_length=1024)
    comment: str | None = Field(default=None, max_length=1024)


async def _get_or_404(session: AsyncSession, auth_id: int) -> Authorization:
    a = await session.get(Authorization, auth_id)
    if a is None:
        raise AuthorizationNotFound(f"authorization {auth_id} not found")
    return a


@router.get("", response_model=ApiResponse[list[AuthorizationOut]])
async def list_authorizations(
    session: Annotated[AsyncSession, Depends(db_session)],
    host_id: int | None = None,
    user_id: int | None = None,
) -> ApiResponse[list[AuthorizationOut]]:
    stmt = select(Authorization).order_by(Authorization.id)
    if host_id is not None:
        stmt = stmt.where(Authorization.host_id == host_id)
    if user_id is not None:
        stmt = stmt.where(Authorization.user_id == user_id)
    rows = (await session.execute(stmt)).scalars().all()
    items = [AuthorizationOut.model_validate(a) for a in rows]
    return ApiResponse[list[AuthorizationOut]].ok(items, meta=Meta(total=len(items)))


@router.get("/{auth_id}", response_model=ApiResponse[AuthorizationOut])
async def get_authorization(
    auth_id: int,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[AuthorizationOut]:
    a = await _get_or_404(session, auth_id)
    return ApiResponse[AuthorizationOut].ok(AuthorizationOut.model_validate(a))


@router.post("", response_model=ApiResponse[AuthorizationOut], status_code=status.HTTP_201_CREATED)
async def create_authorization(
    payload: CreateAuthorizationRequest,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[AuthorizationOut]:
    if await session.get(Host, payload.host_id) is None:
        raise HostNotFound(f"host {payload.host_id} not found")
    if await session.get(User, payload.user_id) is None:
        raise UserNotFound(f"user {payload.user_id} not found")

    a = Authorization(**payload.model_dump())
    session.add(a)
    try:
        await session.flush()
    except IntegrityError as exc:
        raise Conflict(f"authorization violates a uniqueness constraint: {exc.orig}") from exc
    await session.refresh(a)
    return ApiResponse[AuthorizationOut].ok(AuthorizationOut.model_validate(a))


@router.patch("/{auth_id}", response_model=ApiResponse[AuthorizationOut])
async def update_authorization(
    auth_id: int,
    payload: UpdateAuthorizationRequest,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[AuthorizationOut]:
    a = await _get_or_404(session, auth_id)
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(a, field, value)
    try:
        await session.flush()
    except IntegrityError as exc:
        raise Conflict(f"authorization violates a uniqueness constraint: {exc.orig}") from exc
    await session.refresh(a)
    return ApiResponse[AuthorizationOut].ok(AuthorizationOut.model_validate(a))


@router.delete("/{auth_id}", response_model=ApiResponse[dict[str, int]])
async def delete_authorization(
    auth_id: int,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[dict[str, int]]:
    a = await _get_or_404(session, auth_id)
    await session.delete(a)
    return ApiResponse[dict[str, int]].ok({"deleted_id": auth_id})
