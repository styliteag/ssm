"""Shared fixtures for contract tests: TestClient + in-memory DB + JWT."""

from __future__ import annotations

import asyncio
from collections.abc import Iterator
from pathlib import Path

import bcrypt
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from ssm.app import AppDependencies, create_app
from ssm.auth.htpasswd import HtpasswdStore
from ssm.auth.jwt import JwtService
from ssm.db.base import Base
from ssm.ssh.mock import MockSshClient

TEST_SECRET = "contract-test-secret-32-bytes-long-XXXX"


def _make_htpasswd(tmp_path: Path, password: str = "secret") -> HtpasswdStore:
    h = bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt(rounds=4)).decode("utf-8")
    path = tmp_path / ".htpasswd"
    path.write_text(f"admin:{h}\n")
    return HtpasswdStore(path)


@pytest.fixture
def mock_ssh() -> MockSshClient:
    return MockSshClient()


@pytest.fixture
def auth_client(tmp_path: Path, mock_ssh: MockSshClient) -> Iterator[TestClient]:
    """TestClient with an in-memory SQLite DB, migrations applied, JWT + mock SSH wired."""
    engine = create_async_engine("sqlite+aiosqlite:///:memory:", future=True)

    @event.listens_for(engine.sync_engine, "connect")
    def _fk_on(dbapi_connection, _record) -> None:  # type: ignore[no-untyped-def]
        cur = dbapi_connection.cursor()
        cur.execute("PRAGMA foreign_keys=ON")
        cur.close()

    asyncio.run(_create_schema(engine))

    sm = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)
    deps = AppDependencies(
        htpasswd_store=_make_htpasswd(tmp_path),
        jwt_service=JwtService(secret=TEST_SECRET),
        sessionmaker=sm,
        ssh_client=mock_ssh,
    )
    app = create_app(deps)
    with TestClient(app) as client:
        yield client
    asyncio.run(engine.dispose())


async def _create_schema(engine) -> None:  # type: ignore[no-untyped-def]
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


@pytest.fixture
def bearer_token(auth_client: TestClient) -> str:
    resp = auth_client.post("/api/v2/auth/login", json={"username": "admin", "password": "secret"})
    return str(resp.json()["data"]["access_token"])


@pytest.fixture
def auth_headers(bearer_token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {bearer_token}"}
