"""``/api/v2/keys`` — CRUD over SSH public keys belonging to users."""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ssm.auth.deps import protected_router
from ssm.core.envelope import ApiResponse, Meta
from ssm.core.errors import Conflict, KeyNotFound, UserNotFound
from ssm.db.deps import db_session
from ssm.db.models import User, UserKey

router = protected_router(prefix="/keys", tags=["keys"])


class KeyOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    user_id: int
    key_type: str
    key_base64: str
    name: str | None = None
    extra_comment: str | None = None


class CreateKeyRequest(BaseModel):
    user_id: int
    key_type: str = Field(min_length=1, max_length=32)
    key_base64: str = Field(min_length=16, max_length=8192)
    name: str | None = Field(default=None, max_length=128)
    extra_comment: str | None = Field(default=None, max_length=1024)


class UpdateKeyRequest(BaseModel):
    name: str | None = Field(default=None, max_length=128)
    extra_comment: str | None = Field(default=None, max_length=1024)


async def _get_or_404(session: AsyncSession, key_id: int) -> UserKey:
    key = await session.get(UserKey, key_id)
    if key is None:
        raise KeyNotFound(f"key {key_id} not found")
    return key


@router.get("", response_model=ApiResponse[list[KeyOut]])
async def list_keys(
    session: Annotated[AsyncSession, Depends(db_session)],
    user_id: int | None = None,
) -> ApiResponse[list[KeyOut]]:
    stmt = select(UserKey).order_by(UserKey.id)
    if user_id is not None:
        stmt = stmt.where(UserKey.user_id == user_id)
    rows = (await session.execute(stmt)).scalars().all()
    items = [KeyOut.model_validate(k) for k in rows]
    return ApiResponse[list[KeyOut]].ok(items, meta=Meta(total=len(items)))


@router.get("/{key_id}", response_model=ApiResponse[KeyOut])
async def get_key(
    key_id: int,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[KeyOut]:
    key = await _get_or_404(session, key_id)
    return ApiResponse[KeyOut].ok(KeyOut.model_validate(key))


@router.post("", response_model=ApiResponse[KeyOut], status_code=status.HTTP_201_CREATED)
async def create_key(
    payload: CreateKeyRequest,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[KeyOut]:
    owner = await session.get(User, payload.user_id)
    if owner is None:
        raise UserNotFound(f"user {payload.user_id} not found")

    key = UserKey(**payload.model_dump())
    session.add(key)
    try:
        await session.flush()
    except IntegrityError as exc:
        raise Conflict(f"key violates a uniqueness constraint: {exc.orig}") from exc
    await session.refresh(key)
    return ApiResponse[KeyOut].ok(KeyOut.model_validate(key))


@router.patch("/{key_id}", response_model=ApiResponse[KeyOut])
async def update_key(
    key_id: int,
    payload: UpdateKeyRequest,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[KeyOut]:
    key = await _get_or_404(session, key_id)
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(key, field, value)
    await session.flush()
    await session.refresh(key)
    return ApiResponse[KeyOut].ok(KeyOut.model_validate(key))


@router.delete("/{key_id}", response_model=ApiResponse[dict[str, int]])
async def delete_key(
    key_id: int,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[dict[str, int]]:
    key = await _get_or_404(session, key_id)
    await session.delete(key)
    return ApiResponse[dict[str, int]].ok({"deleted_id": key_id})
