"""Tests for SQLAlchemy models — create, relationships, constraints."""

from __future__ import annotations

import pytest
from sqlalchemy import event, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, create_async_engine
from sqlalchemy.orm import sessionmaker

from ssm.db.base import Base
from ssm.db.models import ActivityLog, Authorization, Host, User, UserKey


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
def session_factory(engine: AsyncEngine):  # type: ignore[no-untyped-def]
    return sessionmaker(bind=engine, class_=AsyncSession, expire_on_commit=False)


async def _commit(session_factory, *objs) -> None:  # type: ignore[no-untyped-def]
    async with session_factory() as s:
        for o in objs:
            s.add(o)
        await s.commit()


async def test_create_and_query_host(session_factory) -> None:  # type: ignore[no-untyped-def]
    async with session_factory() as s:
        h = Host(
            name="alpha",
            username="root",
            address="10.0.0.1",
            port=22,
            disabled=False,
        )
        s.add(h)
        await s.commit()

        got = (await s.execute(select(Host).where(Host.name == "alpha"))).scalar_one()
        assert got.username == "root"
        assert got.address == "10.0.0.1"
        assert got.port == 22
        assert got.disabled is False
        assert got.jump_via is None


async def test_host_name_unique(session_factory) -> None:  # type: ignore[no-untyped-def]
    await _commit(session_factory, Host(name="dup", username="u", address="a", port=22))
    with pytest.raises(IntegrityError):
        await _commit(session_factory, Host(name="dup", username="u", address="b", port=22))


async def test_host_address_port_unique(session_factory) -> None:  # type: ignore[no-untyped-def]
    await _commit(session_factory, Host(name="x", username="u", address="1.2.3.4", port=22))
    with pytest.raises(IntegrityError):
        await _commit(session_factory, Host(name="y", username="u", address="1.2.3.4", port=22))


async def test_jump_via_cascade_delete(session_factory) -> None:  # type: ignore[no-untyped-def]
    async with session_factory() as s:
        bastion = Host(name="bastion", username="u", address="1.1.1.1", port=22)
        s.add(bastion)
        await s.commit()
        inner = Host(
            name="inner",
            username="u",
            address="10.0.0.2",
            port=22,
            jump_via=bastion.id,
        )
        s.add(inner)
        await s.commit()
        assert inner.jump_via == bastion.id
        await s.delete(bastion)
        await s.commit()
        remaining = (await s.execute(select(Host))).scalars().all()
        assert remaining == []


async def test_user_defaults_enabled_true(session_factory) -> None:  # type: ignore[no-untyped-def]
    async with session_factory() as s:
        u = User(username="alice")
        s.add(u)
        await s.commit()
        got = (await s.execute(select(User).where(User.username == "alice"))).scalar_one()
        assert got.enabled is True


async def test_authorization_unique_user_host_login(session_factory) -> None:  # type: ignore[no-untyped-def]
    async with session_factory() as s:
        h = Host(name="h", username="u", address="a", port=22)
        u = User(username="alice")
        s.add_all([h, u])
        await s.commit()
        host_id, user_id = h.id, u.id
        s.add(Authorization(host_id=host_id, user_id=user_id, login="root"))
        await s.commit()
    with pytest.raises(IntegrityError):
        await _commit(
            session_factory,
            Authorization(host_id=host_id, user_id=user_id, login="root"),
        )


async def test_user_key_unique_base64(session_factory) -> None:  # type: ignore[no-untyped-def]
    async with session_factory() as s:
        u = User(username="k")
        s.add(u)
        await s.commit()
        user_id = u.id
        s.add(UserKey(key_type="ssh-ed25519", key_base64="AAAA", user_id=user_id))
        await s.commit()
    with pytest.raises(IntegrityError):
        await _commit(
            session_factory,
            UserKey(key_type="ssh-ed25519", key_base64="AAAA", user_id=user_id),
        )


async def test_activity_log_type_check(session_factory) -> None:  # type: ignore[no-untyped-def]
    with pytest.raises(IntegrityError):
        await _commit(
            session_factory,
            ActivityLog(
                activity_type="bogus",
                action="create",
                target="thing",
                actor_username="admin",
            ),
        )


async def test_activity_log_timestamp_default(session_factory) -> None:  # type: ignore[no-untyped-def]
    async with session_factory() as s:
        log = ActivityLog(
            activity_type="host",
            action="create",
            target="h1",
            actor_username="admin",
        )
        s.add(log)
        await s.commit()
        await s.refresh(log)
        assert log.timestamp > 0
