"""Verify the FastAPI lifespan starts and stops the scheduler."""

from __future__ import annotations

import asyncio
from pathlib import Path

import bcrypt
from fastapi.testclient import TestClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from ssm.app import AppDependencies, create_app
from ssm.auth.htpasswd import HtpasswdStore
from ssm.auth.jwt import JwtService
from ssm.db.base import Base
from ssm.scheduler.setup import build_scheduler
from ssm.ssh.mock import MockSshClient


def _make_htpasswd(tmp_path: Path) -> HtpasswdStore:
    h = bcrypt.hashpw(b"secret", bcrypt.gensalt(rounds=4)).decode("utf-8")
    (tmp_path / ".htpasswd").write_text(f"admin:{h}\n")
    return HtpasswdStore(tmp_path / ".htpasswd")


async def _create_schema(engine) -> None:  # type: ignore[no-untyped-def]
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


def test_scheduler_starts_and_stops_with_lifespan(tmp_path: Path) -> None:
    db_path = tmp_path / "ssm.db"
    async_url = f"sqlite+aiosqlite:///{db_path}"
    engine = create_async_engine(async_url, future=True)
    asyncio.run(_create_schema(engine))

    sm = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)
    scheduler = build_scheduler(async_url)

    deps = AppDependencies(
        htpasswd_store=_make_htpasswd(tmp_path),
        jwt_service=JwtService(secret="scheduler-test-secret-32-bytes-long"),
        sessionmaker=sm,
        ssh_client=MockSshClient(),
        scheduler=scheduler,
    )

    app = create_app(deps)
    assert scheduler.running is False

    with TestClient(app):
        assert scheduler.running is True

    assert scheduler.running is False

    asyncio.run(engine.dispose())
