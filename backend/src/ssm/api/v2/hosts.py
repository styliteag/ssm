"""``/api/v2/hosts`` — CRUD over the ``host`` table.

``jump_via`` is a real ``int | None`` on the wire — the Rust backend's
empty-string-as-None deserializer is gone.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, status
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ssm.auth.deps import protected_router
from ssm.core.envelope import ApiResponse, Meta
from ssm.core.errors import Conflict, HostNotFound
from ssm.db.deps import db_session
from ssm.db.models import Host

router = protected_router(prefix="/hosts", tags=["hosts"])


class HostOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    name: str
    username: str
    address: str
    port: int
    key_fingerprint: str | None = None
    jump_via: int | None = None
    disabled: bool = False
    comment: str | None = None


class CreateHostRequest(BaseModel):
    name: str = Field(min_length=1, max_length=128)
    username: str = Field(min_length=1, max_length=128)
    address: str = Field(min_length=1, max_length=253)
    port: int = Field(default=22, gt=0, le=65535)
    key_fingerprint: str | None = None
    jump_via: int | None = None
    disabled: bool = False
    comment: str | None = Field(default=None, max_length=1024)


class UpdateHostRequest(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=128)
    username: str | None = Field(default=None, min_length=1, max_length=128)
    address: str | None = Field(default=None, min_length=1, max_length=253)
    port: int | None = Field(default=None, gt=0, le=65535)
    key_fingerprint: str | None = None
    jump_via: int | None = None
    disabled: bool | None = None
    comment: str | None = Field(default=None, max_length=1024)


async def _get_or_404(session: AsyncSession, host_id: int) -> Host:
    host = await session.get(Host, host_id)
    if host is None:
        raise HostNotFound(f"host {host_id} not found")
    return host


@router.get("", response_model=ApiResponse[list[HostOut]])
async def list_hosts(
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[list[HostOut]]:
    rows = (await session.execute(select(Host).order_by(Host.id))).scalars().all()
    items = [HostOut.model_validate(h) for h in rows]
    return ApiResponse[list[HostOut]].ok(items, meta=Meta(total=len(items)))


@router.get("/{host_id}", response_model=ApiResponse[HostOut])
async def get_host(
    host_id: int,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[HostOut]:
    host = await _get_or_404(session, host_id)
    return ApiResponse[HostOut].ok(HostOut.model_validate(host))


@router.post("", response_model=ApiResponse[HostOut], status_code=status.HTTP_201_CREATED)
async def create_host(
    payload: CreateHostRequest,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[HostOut]:
    if payload.jump_via is not None:
        jump = await session.get(Host, payload.jump_via)
        if jump is None:
            raise HostNotFound(f"jump_via host {payload.jump_via} not found")

    host = Host(**payload.model_dump())
    session.add(host)
    try:
        await session.flush()
    except IntegrityError as exc:
        raise Conflict(f"host violates a uniqueness constraint: {exc.orig}") from exc
    await session.refresh(host)
    return ApiResponse[HostOut].ok(HostOut.model_validate(host))


@router.patch("/{host_id}", response_model=ApiResponse[HostOut])
async def update_host(
    host_id: int,
    payload: UpdateHostRequest,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[HostOut]:
    host = await _get_or_404(session, host_id)
    changes = payload.model_dump(exclude_unset=True)

    if "jump_via" in changes and changes["jump_via"] is not None:
        if changes["jump_via"] == host_id:
            raise Conflict("host cannot jump via itself")
        jump = await session.get(Host, changes["jump_via"])
        if jump is None:
            raise HostNotFound(f"jump_via host {changes['jump_via']} not found")

    for field, value in changes.items():
        setattr(host, field, value)
    try:
        await session.flush()
    except IntegrityError as exc:
        raise Conflict(f"host violates a uniqueness constraint: {exc.orig}") from exc
    await session.refresh(host)
    return ApiResponse[HostOut].ok(HostOut.model_validate(host))


@router.delete("/{host_id}", response_model=ApiResponse[dict[str, int]])
async def delete_host(
    host_id: int,
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[dict[str, int]]:
    host = await _get_or_404(session, host_id)
    await session.delete(host)
    return ApiResponse[dict[str, int]].ok({"deleted_id": host_id})
