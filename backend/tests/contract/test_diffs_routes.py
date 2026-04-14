"""Contract tests for GET /api/v2/diffs/{host_id}."""

from __future__ import annotations

from fastapi.testclient import TestClient

from ssm.ssh.mock import MockSshClient


def _make_user(client: TestClient, headers: dict[str, str], username: str) -> int:
    r = client.post("/api/v2/users", json={"username": username}, headers=headers)
    assert r.status_code == 201
    return int(r.json()["data"]["id"])


def _make_host(
    client: TestClient,
    headers: dict[str, str],
    *,
    name: str,
    address: str,
    disabled: bool = False,
) -> int:
    r = client.post(
        "/api/v2/hosts",
        json={
            "name": name,
            "username": "root",
            "address": address,
            "port": 22,
            "disabled": disabled,
        },
        headers=headers,
    )
    assert r.status_code == 201
    return int(r.json()["data"]["id"])


def _make_key(
    client: TestClient,
    headers: dict[str, str],
    *,
    user_id: int,
    key_base64: str,
    name: str = "laptop",
) -> None:
    r = client.post(
        "/api/v2/keys",
        json={
            "user_id": user_id,
            "key_type": "ssh-ed25519",
            "key_base64": key_base64,
            "name": name,
        },
        headers=headers,
    )
    assert r.status_code == 201, r.text


def _make_auth(
    client: TestClient, headers: dict[str, str], *, host_id: int, user_id: int, login: str
) -> None:
    r = client.post(
        "/api/v2/authorizations",
        json={"host_id": host_id, "user_id": user_id, "login": login},
        headers=headers,
    )
    assert r.status_code == 201, r.text


def test_diff_requires_auth(auth_client: TestClient) -> None:
    r = auth_client.get("/api/v2/diffs/1")
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "AUTH_REQUIRED"


def test_diff_404_for_missing_host(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    r = auth_client.get("/api/v2/diffs/999", headers=auth_headers)
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "HOST_NOT_FOUND"


def test_diff_blocks_disabled_host(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    hid = _make_host(auth_client, auth_headers, name="h", address="1.1.1.1", disabled=True)
    r = auth_client.get(f"/api/v2/diffs/{hid}", headers=auth_headers)
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "HOST_DISABLED"


def test_diff_reports_present_missing_extra(
    auth_client: TestClient, auth_headers: dict[str, str], mock_ssh: MockSshClient
) -> None:
    uid = _make_user(auth_client, auth_headers, "alice")
    _make_key(auth_client, auth_headers, user_id=uid, key_base64="A" * 64, name="laptop")
    _make_key(auth_client, auth_headers, user_id=uid, key_base64="B" * 64, name="yubi")
    hid = _make_host(auth_client, auth_headers, name="h", address="10.0.0.1")
    _make_auth(auth_client, auth_headers, host_id=hid, user_id=uid, login="deploy")

    # Host contains one expected key + one stray key.
    mock_ssh.set_file(
        host_id=hid,
        path="/home/deploy/.ssh/authorized_keys",
        content=(f"ssh-ed25519 {'A' * 64} laptop\nssh-rsa {'Z' * 64} someone-else\n"),
    )

    r = auth_client.get(f"/api/v2/diffs/{hid}", headers=auth_headers)
    assert r.status_code == 200
    body = r.json()["data"]
    assert body["disabled"] is False

    logins = body["logins"]
    assert len(logins) == 1
    diff = logins[0]
    assert diff["login"] == "deploy"
    assert diff["read_error"] is None

    statuses = {(item["status"], item["line"]) for item in diff["items"]}
    assert ("present", f"ssh-ed25519 {'A' * 64} laptop") in statuses
    assert ("missing_on_host", f"ssh-ed25519 {'B' * 64} yubi") in statuses
    assert ("extra_on_host", f"ssh-rsa {'Z' * 64} someone-else") in statuses


def test_diff_read_error_surfaces_on_login(
    auth_client: TestClient, auth_headers: dict[str, str], mock_ssh: MockSshClient
) -> None:
    uid = _make_user(auth_client, auth_headers, "alice")
    _make_key(auth_client, auth_headers, user_id=uid, key_base64="A" * 64)
    hid = _make_host(auth_client, auth_headers, name="h", address="10.0.0.1")
    _make_auth(auth_client, auth_headers, host_id=hid, user_id=uid, login="deploy")
    # Do NOT set_file — MockSshClient will raise SshConnectFailed.

    r = auth_client.get(f"/api/v2/diffs/{hid}", headers=auth_headers)
    assert r.status_code == 200
    diff = r.json()["data"]["logins"][0]
    assert diff["read_error"] is not None
    assert "no file scripted" in diff["read_error"].lower()
    # Expected keys still show up as missing on the host.
    assert any(item["status"] == "missing_on_host" for item in diff["items"])


def test_diff_ignores_comments_and_blank_lines(
    auth_client: TestClient, auth_headers: dict[str, str], mock_ssh: MockSshClient
) -> None:
    uid = _make_user(auth_client, auth_headers, "alice")
    _make_key(auth_client, auth_headers, user_id=uid, key_base64="A" * 64, name="laptop")
    hid = _make_host(auth_client, auth_headers, name="h", address="10.0.0.1")
    _make_auth(auth_client, auth_headers, host_id=hid, user_id=uid, login="deploy")

    mock_ssh.set_file(
        host_id=hid,
        path="/home/deploy/.ssh/authorized_keys",
        content="# managed by ssm\n\nssh-ed25519 " + "A" * 64 + " laptop\n",
    )

    r = auth_client.get(f"/api/v2/diffs/{hid}", headers=auth_headers)
    items = r.json()["data"]["logins"][0]["items"]
    assert len(items) == 1
    assert items[0]["status"] == "present"
