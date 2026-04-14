"""FastAPI dependency that yields an async SQLAlchemy session."""

from __future__ import annotations

from collections.abc import AsyncIterator

from fastapi import Request
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker


def get_sessionmaker(request: Request) -> async_sessionmaker[AsyncSession]:
    sm = getattr(request.app.state, "sessionmaker", None)
    if sm is None:
        msg = "sessionmaker not configured on app.state"
        raise RuntimeError(msg)
    return sm  # type: ignore[no-any-return]


async def db_session(request: Request) -> AsyncIterator[AsyncSession]:
    sm = get_sessionmaker(request)
    async with sm() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
