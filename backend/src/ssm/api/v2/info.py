"""``/api/v2/info`` — server name, version, and applied alembic revision."""

from __future__ import annotations

from importlib.metadata import PackageNotFoundError, version
from typing import Annotated

from fastapi import Depends
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from ssm.auth.deps import protected_router
from ssm.core.envelope import ApiResponse
from ssm.db.deps import db_session

router = protected_router(prefix="/info", tags=["info"])


class ServerInfo(BaseModel):
    name: str
    version: str
    alembic_revision: str | None


def _backend_version() -> str:
    try:
        return version("ssm")
    except PackageNotFoundError:
        return "unknown"


@router.get("", response_model=ApiResponse[ServerInfo])
async def get_info(
    session: Annotated[AsyncSession, Depends(db_session)],
) -> ApiResponse[ServerInfo]:
    row = (
        await session.execute(text("SELECT version_num FROM alembic_version LIMIT 1"))
    ).first()
    revision = row[0] if row is not None else None

    return ApiResponse.ok(
        ServerInfo(name="ssm", version=_backend_version(), alembic_revision=revision)
    )
