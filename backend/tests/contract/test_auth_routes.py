"""Contract tests for /api/v2/auth/* — envelope shape + behaviour."""

from __future__ import annotations

from pathlib import Path

import bcrypt
import pytest
from fastapi.testclient import TestClient

from ssm.app import AppDependencies, create_app
from ssm.auth.htpasswd import HtpasswdStore
from ssm.auth.jwt import JwtService

TEST_SECRET = "a-test-secret-that-is-long-enough-32bytes"


def _htpasswd(tmp_path: Path, password: str = "secret", user: str = "admin") -> HtpasswdStore:
    h = bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt(rounds=4)).decode("utf-8")
    (tmp_path / ".htpasswd").write_text(f"{user}:{h}\n")
    return HtpasswdStore(tmp_path / ".htpasswd")


@pytest.fixture
def client(tmp_path: Path) -> TestClient:
    deps = AppDependencies(
        htpasswd_store=_htpasswd(tmp_path),
        jwt_service=JwtService(secret=TEST_SECRET),
    )
    return TestClient(create_app(deps))


def test_login_success_returns_token_pair(client: TestClient) -> None:
    resp = client.post("/api/v2/auth/login", json={"username": "admin", "password": "secret"})

    assert resp.status_code == 200
    body = resp.json()
    assert body["success"] is True
    assert body["error"] is None
    tp = body["data"]
    assert tp["access_token"]
    assert tp["refresh_token"]
    assert tp["token_type"] == "Bearer"


def test_login_wrong_password_returns_invalid_credentials(client: TestClient) -> None:
    resp = client.post("/api/v2/auth/login", json={"username": "admin", "password": "nope"})

    assert resp.status_code == 401
    body = resp.json()
    assert body["success"] is False
    assert body["error"]["code"] == "INVALID_CREDENTIALS"
    assert body["data"] is None


def test_login_unknown_user_returns_invalid_credentials(client: TestClient) -> None:
    resp = client.post("/api/v2/auth/login", json={"username": "ghost", "password": "x"})

    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "INVALID_CREDENTIALS"


def test_login_validation_error_on_empty_payload(client: TestClient) -> None:
    resp = client.post("/api/v2/auth/login", json={})

    assert resp.status_code == 422
    body = resp.json()
    assert body["error"]["code"] == "VALIDATION_FAILED"


def test_refresh_returns_new_token_pair(client: TestClient) -> None:
    login = client.post(
        "/api/v2/auth/login", json={"username": "admin", "password": "secret"}
    ).json()
    refresh_token = login["data"]["refresh_token"]

    resp = client.post("/api/v2/auth/refresh", json={"refresh_token": refresh_token})

    assert resp.status_code == 200
    body = resp.json()
    assert body["success"] is True
    assert body["data"]["access_token"]
    assert body["data"]["refresh_token"]


def test_refresh_rejects_access_token(client: TestClient) -> None:
    login = client.post(
        "/api/v2/auth/login", json={"username": "admin", "password": "secret"}
    ).json()
    access = login["data"]["access_token"]

    resp = client.post("/api/v2/auth/refresh", json={"refresh_token": access})

    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "AUTH_REQUIRED"


def test_refresh_rejects_malformed(client: TestClient) -> None:
    resp = client.post("/api/v2/auth/refresh", json={"refresh_token": "not-a-token"})

    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "AUTH_REQUIRED"


def test_logout_always_succeeds(client: TestClient) -> None:
    resp = client.post("/api/v2/auth/logout")

    assert resp.status_code == 200
    body = resp.json()
    assert body["success"] is True
    assert body["data"] == {"logged_out": True}


def test_me_requires_bearer_token(client: TestClient) -> None:
    resp = client.get("/api/v2/auth/me")

    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "AUTH_REQUIRED"


def test_me_returns_username_for_valid_access_token(client: TestClient) -> None:
    login = client.post(
        "/api/v2/auth/login", json={"username": "admin", "password": "secret"}
    ).json()
    access = login["data"]["access_token"]

    resp = client.get("/api/v2/auth/me", headers={"Authorization": f"Bearer {access}"})

    assert resp.status_code == 200
    body = resp.json()
    assert body["success"] is True
    assert body["data"] == {"username": "admin"}


def test_me_rejects_refresh_token(client: TestClient) -> None:
    login = client.post(
        "/api/v2/auth/login", json={"username": "admin", "password": "secret"}
    ).json()
    refresh = login["data"]["refresh_token"]

    resp = client.get("/api/v2/auth/me", headers={"Authorization": f"Bearer {refresh}"})

    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "AUTH_REQUIRED"


def test_openapi_document_is_generated(client: TestClient) -> None:
    resp = client.get("/api/v2/openapi.json")
    assert resp.status_code == 200
    paths = resp.json()["paths"]
    assert "/api/v2/auth/login" in paths
    assert "/api/v2/auth/refresh" in paths
    assert "/api/v2/auth/logout" in paths
    assert "/api/v2/auth/me" in paths
