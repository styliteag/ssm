"""Contract tests for GET /api/v2/activity-log — pagination + meta."""

from __future__ import annotations

import asyncio

from fastapi.testclient import TestClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from ssm.db.models import ActivityLog


async def _seed(sm: async_sessionmaker[AsyncSession], rows: list[ActivityLog]) -> None:
    async with sm() as session:
        for r in rows:
            session.add(r)
        await session.commit()


def _sessionmaker(client: TestClient) -> async_sessionmaker[AsyncSession]:
    sm = client.app.state.sessionmaker
    assert sm is not None
    return sm  # type: ignore[no-any-return]


def test_list_requires_auth(auth_client: TestClient) -> None:
    r = auth_client.get("/api/v2/activity-log")
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "AUTH_REQUIRED"


def test_empty_list_returns_meta(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    r = auth_client.get("/api/v2/activity-log", headers=auth_headers)
    assert r.status_code == 200
    body = r.json()
    assert body["data"] == []
    assert body["meta"] == {"total": 0, "page": 1, "page_size": 50}


def test_pagination_splits_rows(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    sm = _sessionmaker(auth_client)
    rows = [
        ActivityLog(
            activity_type="host",
            action="create",
            target=f"h{i}",
            actor_username="admin",
            timestamp=1_700_000_000 + i,
        )
        for i in range(7)
    ]
    asyncio.run(_seed(sm, rows))

    r = auth_client.get("/api/v2/activity-log?page=1&page_size=3", headers=auth_headers)
    body = r.json()
    assert body["meta"] == {"total": 7, "page": 1, "page_size": 3}
    assert [item["target"] for item in body["data"]] == ["h6", "h5", "h4"]

    r = auth_client.get("/api/v2/activity-log?page=3&page_size=3", headers=auth_headers)
    body = r.json()
    assert body["meta"]["page"] == 3
    assert [item["target"] for item in body["data"]] == ["h0"]


def test_filter_by_activity_type(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    sm = _sessionmaker(auth_client)
    rows = [
        ActivityLog(
            activity_type="host",
            action="create",
            target="h1",
            actor_username="admin",
            timestamp=1_700_000_000,
        ),
        ActivityLog(
            activity_type="user",
            action="create",
            target="u1",
            actor_username="admin",
            timestamp=1_700_000_001,
        ),
        ActivityLog(
            activity_type="user",
            action="delete",
            target="u1",
            actor_username="admin",
            timestamp=1_700_000_002,
        ),
    ]
    asyncio.run(_seed(sm, rows))

    r = auth_client.get("/api/v2/activity-log?activity_type=user", headers=auth_headers)
    body = r.json()
    assert body["meta"]["total"] == 2
    assert all(item["activity_type"] == "user" for item in body["data"])


def test_page_size_bounds_are_enforced(
    auth_client: TestClient, auth_headers: dict[str, str]
) -> None:
    r = auth_client.get("/api/v2/activity-log?page_size=0", headers=auth_headers)
    assert r.status_code == 422
    assert r.json()["error"]["code"] == "VALIDATION_FAILED"

    r = auth_client.get("/api/v2/activity-log?page_size=1000", headers=auth_headers)
    assert r.status_code == 422
