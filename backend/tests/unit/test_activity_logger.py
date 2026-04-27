"""Tests for ssm.activity_logger.log_activity."""

from __future__ import annotations

import json

import pytest
from sqlalchemy import event, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from ssm.activity_logger import ActivityType, log_activity
from ssm.db.base import Base
from ssm.db.models import ActivityLog, User


@pytest.fixture
async def engine() -> AsyncEngine:
    eng = create_async_engine("sqlite+aiosqlite:///:memory:", future=True)

    @event.listens_for(eng.sync_engine, "connect")
    def _fk_on(dbapi_connection, _record) -> None:  # type: ignore[no-untyped-def]
        cur = dbapi_connection.cursor()
        cur.execute("PRAGMA foreign_keys=ON")
        cur.close()

    async with eng.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    try:
        yield eng
    finally:
        await eng.dispose()


@pytest.fixture
def sm(engine: AsyncEngine) -> async_sessionmaker[AsyncSession]:
    return async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)


async def test_inserts_minimal_entry(sm: async_sessionmaker[AsyncSession]) -> None:
    async with sm() as session:
        entry = await log_activity(
            session,
            activity_type=ActivityType.HOST,
            action="create",
            target="web-1",
            actor_username="admin",
        )
        await session.commit()

    async with sm() as session:
        rows = (await session.execute(select(ActivityLog))).scalars().all()
    assert len(rows) == 1
    row = rows[0]
    assert row.id == entry.id
    assert row.activity_type == "host"
    assert row.action == "create"
    assert row.target == "web-1"
    assert row.actor_username == "admin"
    assert row.user_id is None
    assert row.meta is None
    assert row.timestamp > 0


async def test_serialises_details_as_json(sm: async_sessionmaker[AsyncSession]) -> None:
    async with sm() as session:
        await log_activity(
            session,
            activity_type=ActivityType.KEY,
            action="add",
            target="alice:laptop",
            actor_username="admin",
            details={"key_type": "ssh-ed25519", "fingerprint": "SHA256:xyz"},
        )
        await session.commit()

    async with sm() as session:
        row = (await session.execute(select(ActivityLog))).scalar_one()
    parsed = json.loads(str(row.meta))
    assert parsed == {"key_type": "ssh-ed25519", "fingerprint": "SHA256:xyz"}


async def test_sets_explicit_timestamp(sm: async_sessionmaker[AsyncSession]) -> None:
    async with sm() as session:
        await log_activity(
            session,
            activity_type=ActivityType.USER,
            action="delete",
            target="bob",
            actor_username="admin",
            timestamp=1_700_000_000,
        )
        await session.commit()

    async with sm() as session:
        row = (await session.execute(select(ActivityLog))).scalar_one()
    assert row.timestamp == 1_700_000_000


async def test_links_to_user_id(sm: async_sessionmaker[AsyncSession]) -> None:
    async with sm() as session:
        user = User(username="alice")
        session.add(user)
        await session.commit()
        await log_activity(
            session,
            activity_type=ActivityType.AUTH,
            action="grant",
            target="alice@web-1",
            actor_username="admin",
            user_id=user.id,
        )
        await session.commit()

    async with sm() as session:
        row = (await session.execute(select(ActivityLog))).scalar_one()
    assert row.user_id == user.id


async def test_rejects_invalid_activity_type_at_db_layer(
    sm: async_sessionmaker[AsyncSession],
) -> None:
    """Direct DB insert with an unknown type is stopped by the CHECK constraint."""
    with pytest.raises(IntegrityError):
        async with sm() as session:
            session.add(
                ActivityLog(
                    activity_type="bogus",
                    action="x",
                    target="y",
                    actor_username="admin",
                )
            )
            await session.commit()
