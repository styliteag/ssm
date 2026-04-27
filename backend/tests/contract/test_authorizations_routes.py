"""Contract tests for /api/v2/authorizations CRUD."""

from __future__ import annotations

from fastapi.testclient import TestClient


def _make_user(client: TestClient, headers: dict[str, str], username: str) -> int:
    r = client.post("/api/v2/users", json={"username": username}, headers=headers)
    assert r.status_code == 201
    return int(r.json()["data"]["id"])


def _make_host(client: TestClient, headers: dict[str, str], name: str, address: str) -> int:
    r = client.post(
        "/api/v2/hosts",
        json={"name": name, "username": "root", "address": address, "port": 22},
        headers=headers,
    )
    assert r.status_code == 201
    return int(r.json()["data"]["id"])


def _make_auth(
    client: TestClient,
    headers: dict[str, str],
    *,
    host_id: int,
    user_id: int,
    login: str,
    **overrides: object,
) -> dict[str, object]:
    payload: dict[str, object] = {
        "host_id": host_id,
        "user_id": user_id,
        "login": login,
    }
    payload.update(overrides)
    r = client.post("/api/v2/authorizations", json=payload, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()["data"]  # type: ignore[no-any-return]


def test_list_requires_auth(auth_client: TestClient) -> None:
    r = auth_client.get("/api/v2/authorizations")
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "AUTH_REQUIRED"


def test_create_requires_existing_host(
    auth_client: TestClient, auth_headers: dict[str, str]
) -> None:
    uid = _make_user(auth_client, auth_headers, "alice")
    r = auth_client.post(
        "/api/v2/authorizations",
        json={"host_id": 999, "user_id": uid, "login": "root"},
        headers=auth_headers,
    )
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "HOST_NOT_FOUND"


def test_create_requires_existing_user(
    auth_client: TestClient, auth_headers: dict[str, str]
) -> None:
    hid = _make_host(auth_client, auth_headers, "h", "1.1.1.1")
    r = auth_client.post(
        "/api/v2/authorizations",
        json={"host_id": hid, "user_id": 999, "login": "root"},
        headers=auth_headers,
    )
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "USER_NOT_FOUND"


def test_create_and_list_filters(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    uid1 = _make_user(auth_client, auth_headers, "u1")
    uid2 = _make_user(auth_client, auth_headers, "u2")
    hid1 = _make_host(auth_client, auth_headers, "h1", "1.1.1.1")
    hid2 = _make_host(auth_client, auth_headers, "h2", "1.1.1.2")

    _make_auth(auth_client, auth_headers, host_id=hid1, user_id=uid1, login="root")
    _make_auth(auth_client, auth_headers, host_id=hid1, user_id=uid2, login="deploy")
    _make_auth(auth_client, auth_headers, host_id=hid2, user_id=uid1, login="root")

    r = auth_client.get(f"/api/v2/authorizations?host_id={hid1}", headers=auth_headers)
    assert r.status_code == 200
    items = r.json()["data"]
    assert len(items) == 2
    assert {a["login"] for a in items} == {"root", "deploy"}

    r = auth_client.get(
        f"/api/v2/authorizations?user_id={uid1}&host_id={hid1}", headers=auth_headers
    )
    assert len(r.json()["data"]) == 1


def test_duplicate_triple_is_conflict(
    auth_client: TestClient, auth_headers: dict[str, str]
) -> None:
    uid = _make_user(auth_client, auth_headers, "alice")
    hid = _make_host(auth_client, auth_headers, "h", "1.1.1.1")
    _make_auth(auth_client, auth_headers, host_id=hid, user_id=uid, login="root")

    r = auth_client.post(
        "/api/v2/authorizations",
        json={"host_id": hid, "user_id": uid, "login": "root"},
        headers=auth_headers,
    )
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "CONFLICT"


def test_patch_login(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    uid = _make_user(auth_client, auth_headers, "alice")
    hid = _make_host(auth_client, auth_headers, "h", "1.1.1.1")
    created = _make_auth(auth_client, auth_headers, host_id=hid, user_id=uid, login="root")

    r = auth_client.patch(
        f"/api/v2/authorizations/{created['id']}",
        json={"login": "deploy", "options": "no-pty"},
        headers=auth_headers,
    )
    assert r.status_code == 200
    data = r.json()["data"]
    assert data["login"] == "deploy"
    assert data["options"] == "no-pty"


def test_delete_authorization(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    uid = _make_user(auth_client, auth_headers, "alice")
    hid = _make_host(auth_client, auth_headers, "h", "1.1.1.1")
    created = _make_auth(auth_client, auth_headers, host_id=hid, user_id=uid, login="root")

    r = auth_client.delete(f"/api/v2/authorizations/{created['id']}", headers=auth_headers)
    assert r.status_code == 200
    assert r.json()["data"] == {"deleted_id": created["id"]}

    r = auth_client.get(f"/api/v2/authorizations/{created['id']}", headers=auth_headers)
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "AUTHORIZATION_NOT_FOUND"
