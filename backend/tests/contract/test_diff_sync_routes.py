"""Contract tests for POST /api/v2/diffs/{host_id}/sync."""

from __future__ import annotations

from fastapi.testclient import TestClient

from ssm.ssh.mock import MockSshClient
from ssm.ssh.protocol import SshResult


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
    client: TestClient, headers: dict[str, str], *, user_id: int, key_base64: str
) -> None:
    r = client.post(
        "/api/v2/keys",
        json={
            "user_id": user_id,
            "key_type": "ssh-ed25519",
            "key_base64": key_base64,
            "name": "laptop",
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


def _allow_writable(mock: MockSshClient) -> None:
    """``ensure_writable`` runs a shell probe whose empty stdout means writable."""
    mock.default_exec = SshResult(stdout="", stderr="", exit_code=0)


def test_sync_requires_auth(auth_client: TestClient) -> None:
    r = auth_client.post("/api/v2/diffs/1/sync")
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "AUTH_REQUIRED"


def test_sync_404_for_missing_host(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    r = auth_client.post("/api/v2/diffs/999/sync", headers=auth_headers)
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "HOST_NOT_FOUND"


def test_sync_blocks_disabled_host(auth_client: TestClient, auth_headers: dict[str, str]) -> None:
    hid = _make_host(auth_client, auth_headers, name="h", address="1.1.1.1", disabled=True)
    r = auth_client.post(f"/api/v2/diffs/{hid}/sync", headers=auth_headers)
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "HOST_DISABLED"


def test_sync_blocks_readonly_host(
    auth_client: TestClient, auth_headers: dict[str, str], mock_ssh: MockSshClient
) -> None:
    uid = _make_user(auth_client, auth_headers, "alice")
    _make_key(auth_client, auth_headers, user_id=uid, key_base64="A" * 64)
    hid = _make_host(auth_client, auth_headers, name="h", address="10.0.0.1")
    _make_auth(auth_client, auth_headers, host_id=hid, user_id=uid, login="deploy")

    mock_ssh.default_exec = SshResult(stdout="system_readonly: freeze\n", stderr="", exit_code=0)

    r = auth_client.post(f"/api/v2/diffs/{hid}/sync", headers=auth_headers)
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "SSH_READONLY"
    # No writes should have happened.
    assert mock_ssh.write_calls == []


def test_sync_writes_expected_keys(
    auth_client: TestClient, auth_headers: dict[str, str], mock_ssh: MockSshClient
) -> None:
    uid = _make_user(auth_client, auth_headers, "alice")
    _make_key(auth_client, auth_headers, user_id=uid, key_base64="A" * 64)
    _make_key(
        auth_client,
        auth_headers,
        user_id=uid,
        key_base64="B" * 64,
    )
    hid = _make_host(auth_client, auth_headers, name="h", address="10.0.0.1")
    _make_auth(auth_client, auth_headers, host_id=hid, user_id=uid, login="deploy")

    _allow_writable(mock_ssh)

    r = auth_client.post(f"/api/v2/diffs/{hid}/sync", headers=auth_headers)
    assert r.status_code == 200, r.text
    body = r.json()["data"]
    assert body["host_id"] == hid
    assert body["logins"] == [{"login": "deploy", "written_keys": 2}]

    # Exactly one write happened, with both key lines.
    assert len(mock_ssh.write_calls) == 1
    host_id, path, content = mock_ssh.write_calls[0]
    assert host_id == hid
    assert path == "/home/deploy/.ssh/authorized_keys"
    lines = [line for line in content.splitlines() if line.strip()]
    assert len(lines) == 2
    assert any("A" * 64 in line for line in lines)
    assert any("B" * 64 in line for line in lines)


def test_sync_noop_when_no_authorizations(
    auth_client: TestClient, auth_headers: dict[str, str], mock_ssh: MockSshClient
) -> None:
    hid = _make_host(auth_client, auth_headers, name="h", address="10.0.0.1")
    _allow_writable(mock_ssh)

    r = auth_client.post(f"/api/v2/diffs/{hid}/sync", headers=auth_headers)
    assert r.status_code == 200
    assert r.json()["data"]["logins"] == []
    assert mock_ssh.write_calls == []
