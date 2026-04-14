"""Contract tests for /api/v2/hosts CRUD."""

from __future__ import annotations

from fastapi.testclient import TestClient


def _create(client: TestClient, headers: dict[str, str], **overrides: object) -> dict[str, object]:
    payload: dict[str, object] = {
        "name": "alpha",
        "username": "root",
        "address": "10.0.0.1",
        "port": 22,
    }
    payload.update(overrides)
    resp = client.post("/api/v2/hosts", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert body["success"] is True
    return body["data"]  # type: ignore[no-any-return]


def test_list_requires_auth(auth_client: TestClient) -> None:
    resp = auth_client.get("/api/v2/hosts")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "AUTH_REQUIRED"


def test_list_empty(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    resp = auth_client.get("/api/v2/hosts", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["success"] is True
    assert body["data"] == []
    assert body["meta"] == {"total": 0, "page": None, "page_size": None}


def test_create_then_get(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    created = _create(auth_client, auth_headers, name="web-1", address="10.0.0.1")
    assert created["name"] == "web-1"
    assert created["disabled"] is False
    assert created["jump_via"] is None

    host_id = created["id"]
    resp = auth_client.get(f"/api/v2/hosts/{host_id}", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["data"]["name"] == "web-1"


def test_create_with_jump_via_as_int(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    bastion = _create(auth_client, auth_headers, name="bastion", address="1.1.1.1")
    inner = _create(
        auth_client,
        auth_headers,
        name="inner",
        address="10.0.0.2",
        jump_via=bastion["id"],
    )
    assert inner["jump_via"] == bastion["id"]


def test_jump_via_must_reference_existing_host(
    auth_client: TestClient, auth_headers: dict[str, str]
) -> None:
    resp = auth_client.post(
        "/api/v2/hosts",
        json={
            "name": "dangling",
            "username": "root",
            "address": "10.0.0.5",
            "port": 22,
            "jump_via": 999,
        },
        headers=auth_headers,
    )
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "HOST_NOT_FOUND"


def test_jump_via_empty_string_is_rejected(
    auth_client: TestClient, auth_headers: dict[str, str]
) -> None:
    """Sanity: legacy empty-string hack from the Rust backend must now fail validation."""
    resp = auth_client.post(
        "/api/v2/hosts",
        json={
            "name": "legacy",
            "username": "root",
            "address": "10.0.0.9",
            "port": 22,
            "jump_via": "",
        },
        headers=auth_headers,
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "VALIDATION_FAILED"


def test_duplicate_name_is_conflict(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    _create(auth_client, auth_headers, name="x", address="10.0.0.11")
    resp = auth_client.post(
        "/api/v2/hosts",
        json={"name": "x", "username": "root", "address": "10.0.0.12", "port": 22},
        headers=auth_headers,
    )
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "CONFLICT"


def test_patch_disabled_flag(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    created = _create(auth_client, auth_headers, name="togglehost", address="10.0.0.33")
    host_id = created["id"]

    resp = auth_client.patch(
        f"/api/v2/hosts/{host_id}", json={"disabled": True}, headers=auth_headers
    )
    assert resp.status_code == 200
    assert resp.json()["data"]["disabled"] is True
    # Untouched fields stay the same.
    assert resp.json()["data"]["name"] == "togglehost"


def test_patch_rejects_self_jump_via(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    created = _create(auth_client, auth_headers, name="selfjump", address="10.0.0.34")
    resp = auth_client.patch(
        f"/api/v2/hosts/{created['id']}",
        json={"jump_via": created["id"]},
        headers=auth_headers,
    )
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "CONFLICT"


def test_delete_host(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    created = _create(auth_client, auth_headers, name="delme", address="10.0.0.44")
    host_id = created["id"]

    resp = auth_client.delete(f"/api/v2/hosts/{host_id}", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["data"] == {"deleted_id": host_id}

    # Gone now.
    resp = auth_client.get(f"/api/v2/hosts/{host_id}", headers=auth_headers)
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "HOST_NOT_FOUND"


def test_list_reports_total_in_meta(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    _create(auth_client, auth_headers, name="a", address="10.0.0.51")
    _create(auth_client, auth_headers, name="b", address="10.0.0.52")
    _create(auth_client, auth_headers, name="c", address="10.0.0.53")

    body = auth_client.get("/api/v2/hosts", headers=auth_headers).json()
    assert body["meta"]["total"] == 3
    assert len(body["data"]) == 3
