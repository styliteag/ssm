"""Contract tests for /api/v2/users CRUD."""

from __future__ import annotations

from fastapi.testclient import TestClient


def _create(client: TestClient, headers: dict[str, str], **overrides: object) -> dict[str, object]:
    payload: dict[str, object] = {"username": "alice"}
    payload.update(overrides)
    resp = client.post("/api/v2/users", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()["data"]  # type: ignore[no-any-return]


def test_list_requires_auth(auth_client: TestClient) -> None:
    resp = auth_client.get("/api/v2/users")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "AUTH_REQUIRED"


def test_list_empty(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    resp = auth_client.get("/api/v2/users", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["success"] is True
    assert body["data"] == []
    assert body["meta"]["total"] == 0


def test_create_defaults_enabled_true(
    auth_client: TestClient, auth_headers: dict[str, str]
) -> None:
    created = _create(auth_client, auth_headers, username="alice")
    assert created["enabled"] is True
    assert created["comment"] is None


def test_create_duplicate_username_is_conflict(
    auth_client: TestClient, auth_headers: dict[str, str]
) -> None:
    _create(auth_client, auth_headers, username="dup")
    resp = auth_client.post("/api/v2/users", json={"username": "dup"}, headers=auth_headers)
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "CONFLICT"


def test_get_missing_returns_user_not_found(
    auth_client: TestClient, auth_headers: dict[str, str]
) -> None:
    resp = auth_client.get("/api/v2/users/999", headers=auth_headers)
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "USER_NOT_FOUND"


def test_patch_can_disable_user(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    created = _create(auth_client, auth_headers, username="bob")
    resp = auth_client.patch(
        f"/api/v2/users/{created['id']}",
        json={"enabled": False, "comment": "offboarded"},
        headers=auth_headers,
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["enabled"] is False
    assert data["comment"] == "offboarded"
    assert data["username"] == "bob"


def test_delete_user(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    created = _create(auth_client, auth_headers, username="gone")
    resp = auth_client.delete(f"/api/v2/users/{created['id']}", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["data"] == {"deleted_id": created["id"]}

    resp = auth_client.get(f"/api/v2/users/{created['id']}", headers=auth_headers)
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "USER_NOT_FOUND"


def test_create_validation_on_empty_username(
    auth_client: TestClient, auth_headers: dict[str, str]
) -> None:
    resp = auth_client.post("/api/v2/users", json={"username": ""}, headers=auth_headers)
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_FAILED"
