"""Contract tests for /api/v2/keys CRUD."""

from __future__ import annotations

from fastapi.testclient import TestClient


def _create_user(client: TestClient, headers: dict[str, str], username: str) -> int:
    resp = client.post("/api/v2/users", json={"username": username}, headers=headers)
    assert resp.status_code == 201, resp.text
    return int(resp.json()["data"]["id"])


def _create_key(
    client: TestClient, headers: dict[str, str], *, user_id: int, **overrides: object
) -> dict[str, object]:
    payload: dict[str, object] = {
        "user_id": user_id,
        "key_type": "ssh-ed25519",
        "key_base64": "A" * 64,
    }
    payload.update(overrides)
    resp = client.post("/api/v2/keys", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()["data"]  # type: ignore[no-any-return]


def test_list_requires_auth(auth_client: TestClient) -> None:
    resp = auth_client.get("/api/v2/keys")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "AUTH_REQUIRED"


def test_create_needs_existing_user(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    resp = auth_client.post(
        "/api/v2/keys",
        json={
            "user_id": 999,
            "key_type": "ssh-ed25519",
            "key_base64": "B" * 64,
        },
        headers=auth_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "USER_NOT_FOUND"


def test_create_succeeds_and_list_filters_by_user(
    auth_client: TestClient, auth_headers: dict[str, str]
) -> None:
    u1 = _create_user(auth_client, auth_headers, "alice")
    u2 = _create_user(auth_client, auth_headers, "bob")

    _create_key(auth_client, auth_headers, user_id=u1, key_base64="A" * 64, name="alice-1")
    _create_key(auth_client, auth_headers, user_id=u2, key_base64="C" * 64, name="bob-1")

    resp = auth_client.get(f"/api/v2/keys?user_id={u1}", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["data"]) == 1
    assert body["data"][0]["user_id"] == u1
    assert body["meta"]["total"] == 1


def test_duplicate_key_base64_is_conflict(
    auth_client: TestClient, auth_headers: dict[str, str]
) -> None:
    u = _create_user(auth_client, auth_headers, "same")
    _create_key(auth_client, auth_headers, user_id=u, key_base64="D" * 64)

    resp = auth_client.post(
        "/api/v2/keys",
        json={
            "user_id": u,
            "key_type": "ssh-ed25519",
            "key_base64": "D" * 64,
        },
        headers=auth_headers,
    )
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "CONFLICT"


def test_patch_updates_name_only(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    u = _create_user(auth_client, auth_headers, "patchme")
    created = _create_key(auth_client, auth_headers, user_id=u, key_base64="E" * 64, name="old")

    resp = auth_client.patch(
        f"/api/v2/keys/{created['id']}",
        json={"name": "new-name"},
        headers=auth_headers,
    )
    assert resp.status_code == 200
    data = resp.json()["data"]
    assert data["name"] == "new-name"
    assert data["key_base64"] == "E" * 64  # untouched


def test_delete_key(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    u = _create_user(auth_client, auth_headers, "dropkey")
    created = _create_key(auth_client, auth_headers, user_id=u, key_base64="F" * 64)

    resp = auth_client.delete(f"/api/v2/keys/{created['id']}", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["data"] == {"deleted_id": created["id"]}

    resp = auth_client.get(f"/api/v2/keys/{created['id']}", headers=auth_headers)
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "KEY_NOT_FOUND"


def test_validation_rejects_short_key(
    auth_client: TestClient, auth_headers: dict[str, str]
) -> None:
    u = _create_user(auth_client, auth_headers, "shorty")
    resp = auth_client.post(
        "/api/v2/keys",
        json={"user_id": u, "key_type": "ssh-ed25519", "key_base64": "short"},
        headers=auth_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_FAILED"
