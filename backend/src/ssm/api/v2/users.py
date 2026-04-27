"""``/api/v2/users`` — CRUD over the ``user`` table."""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ssm.auth.deps import protected_router
from ssm.core.envelope import ApiResponse, Meta
from ssm.core.errors import Conflict, UserNotFound
from ssm.db.deps import db_session
from ssm.db.models import User

router = protected_router(prefix="/users", tags=["users"])


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    username: str
    enabled: bool = True
    comment: str | None = None


class CreateUserRequest(BaseModel):
    username: str = Field(min_length=1, max_length=128)
    enabled: bool = True
    comment: str | None = Field(default=None, max_length=1024)


class UpdateUserRequest(BaseModel):
    username: str | None = Field(default=None, min_length=1, max_length=128)
    enabled: bool | None = None
    comment: str | None = Field(default=None, max_length=1024)


async def _get_or_404(session: AsyncSession, user_id: int) -> User:
    user = await session.get(User, user_id)
    if user is None:
        raise UserNotFound(f"user {user_id} not found")
    return user


@router.get("", response_model=ApiResponse[list[UserOut]])
async def list_users(
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[list[UserOut]]:
    rows = (await session.execute(select(User).order_by(User.id))).scalars().all()
    items = [UserOut.model_validate(u) for u in rows]
    return ApiResponse[list[UserOut]].ok(items, meta=Meta(total=len(items)))


@router.get("/{user_id}", response_model=ApiResponse[UserOut])
async def get_user(
    user_id: int,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[UserOut]:
    user = await _get_or_404(session, user_id)
    return ApiResponse[UserOut].ok(UserOut.model_validate(user))


@router.post("", response_model=ApiResponse[UserOut], status_code=status.HTTP_201_CREATED)
async def create_user(
    payload: CreateUserRequest,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[UserOut]:
    user = User(**payload.model_dump())
    session.add(user)
    try:
        await session.flush()
    except IntegrityError as exc:
        raise Conflict(f"user violates a uniqueness constraint: {exc.orig}") from exc
    await session.refresh(user)
    return ApiResponse[UserOut].ok(UserOut.model_validate(user))


@router.patch("/{user_id}", response_model=ApiResponse[UserOut])
async def update_user(
    user_id: int,
    payload: UpdateUserRequest,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[UserOut]:
    user = await _get_or_404(session, user_id)
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(user, field, value)
    try:
        await session.flush()
    except IntegrityError as exc:
        raise Conflict(f"user violates a uniqueness constraint: {exc.orig}") from exc
    await session.refresh(user)
    return ApiResponse[UserOut].ok(UserOut.model_validate(user))


@router.delete("/{user_id}", response_model=ApiResponse[dict[str, int]])
async def delete_user(
    user_id: int,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[dict[str, int]]:
    user = await _get_or_404(session, user_id)
    await session.delete(user)
    return ApiResponse[dict[str, int]].ok({"deleted_id": user_id})
