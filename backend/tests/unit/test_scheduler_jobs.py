"""Tests for ssm.scheduler.jobs — poll_connection_status."""

from __future__ import annotations

import pytest
from sqlalchemy import event
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from ssm.db.base import Base
from ssm.db.models import Host
from ssm.scheduler.jobs import poll_connection_status
from ssm.ssh.mock import MockSshClient


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


async def _seed_host(sm: async_sessionmaker[AsyncSession], **kw: object) -> int:
    async with sm() as s:
        h = Host(
            name=str(kw.get("name", "h")),
            username=str(kw.get("username", "root")),
            address=str(kw.get("address", "10.0.0.1")),
            port=int(kw.get("port", 22)),  # type: ignore[arg-type]
            disabled=bool(kw.get("disabled", False)),
        )
        s.add(h)
        await s.commit()
        return int(h.id)


async def test_poll_all_reachable(sm: async_sessionmaker[AsyncSession]) -> None:
    await _seed_host(sm, name="a", address="10.0.0.1")
    await _seed_host(sm, name="b", address="10.0.0.2")
    mock = MockSshClient()

    result = await poll_connection_status(sm, mock)

    assert result.checked == 2
    assert result.reachable == 2
    assert result.failed == 0
    assert result.skipped_disabled == 0
    assert sorted(s.reachable for s in result.statuses) == [True, True]


async def test_disabled_hosts_are_skipped(sm: async_sessionmaker[AsyncSession]) -> None:
    await _seed_host(sm, name="a", address="10.0.0.1")
    await _seed_host(sm, name="b", address="10.0.0.2", disabled=True)
    mock = MockSshClient()

    result = await poll_connection_status(sm, mock)

    assert result.checked == 1
    assert result.reachable == 1
    assert result.skipped_disabled == 1
    # SSH client was never asked about the disabled host.
    assert mock.connect_calls == [1]


async def test_unreachable_host_is_captured(sm: async_sessionmaker[AsyncSession]) -> None:
    host_id = await _seed_host(sm, name="dead", address="10.0.0.99")
    mock = MockSshClient()
    mock.fail_connect(host_id)

    result = await poll_connection_status(sm, mock)

    assert result.checked == 1
    assert result.reachable == 0
    assert result.failed == 1
    assert result.statuses[0].host_id == host_id
    assert result.statuses[0].reachable is False
    assert result.statuses[0].error is not None


async def test_jump_host_chain_is_probed(sm: async_sessionmaker[AsyncSession]) -> None:
    bastion_id = await _seed_host(sm, name="bastion", address="1.1.1.1")
    async with sm() as s:
        inner = Host(
            name="inner",
            username="root",
            address="10.0.0.2",
            port=22,
            jump_via=bastion_id,
        )
        s.add(inner)
        await s.commit()
    mock = MockSshClient()

    result = await poll_connection_status(sm, mock)

    assert result.reachable == 2
    # Both hosts visited. (The mock only records connect_calls for its own target.)
    assert set(mock.connect_calls) == {bastion_id, inner.id}
