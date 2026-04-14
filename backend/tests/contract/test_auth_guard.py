"""Contract tests for the 401 envelope shape on ``protected_router`` routes."""

from __future__ import annotations

import time
from pathlib import Path

import bcrypt
import jwt as pyjwt
import pytest
from fastapi.testclient import TestClient

from ssm.app import AppDependencies, create_app
from ssm.auth.deps import protected_router
from ssm.auth.htpasswd import HtpasswdStore
from ssm.auth.jwt import JwtService

TEST_SECRET = "guard-test-secret-that-is-long-enough-XYZ"


def _htpasswd(tmp_path: Path) -> HtpasswdStore:
    h = bcrypt.hashpw(b"secret", bcrypt.gensalt(rounds=4)).decode("utf-8")
    (tmp_path / ".htpasswd").write_text(f"admin:{h}\n")
    return HtpasswdStore(tmp_path / ".htpasswd")


@pytest.fixture
def client(tmp_path: Path) -> TestClient:
    deps = AppDependencies(
        htpasswd_store=_htpasswd(tmp_path),
        jwt_service=JwtService(secret=TEST_SECRET),
    )
    app = create_app(deps)

    r = protected_router(prefix="/api/v2/ping", tags=["ping"])

    @r.get("")
    def ping() -> dict[str, str]:
        return {"pong": "ok"}

    app.include_router(r)
    return TestClient(app)


def _assert_auth_required(body: dict) -> None:  # type: ignore[type-arg]
    assert body["success"] is False
    assert body["data"] is None
    assert body["error"]["code"] == "AUTH_REQUIRED"
    assert body["meta"] is None


def test_missing_bearer_header_returns_auth_required_envelope(client: TestClient) -> None:
    resp = client.get("/api/v2/ping")
    assert resp.status_code == 401
    _assert_auth_required(resp.json())


def test_wrong_scheme_returns_auth_required(client: TestClient) -> None:
    resp = client.get("/api/v2/ping", headers={"Authorization": "Basic dXNlcjpwYXNz"})
    assert resp.status_code == 401
    _assert_auth_required(resp.json())


def test_malformed_token_returns_auth_required(client: TestClient) -> None:
    resp = client.get("/api/v2/ping", headers={"Authorization": "Bearer not-a-jwt"})
    assert resp.status_code == 401
    _assert_auth_required(resp.json())


def test_expired_token_returns_auth_required(client: TestClient) -> None:
    now = int(time.time())
    expired = pyjwt.encode(
        {"sub": "admin", "iat": now - 7200, "exp": now - 60, "type": "access"},
        TEST_SECRET,
        algorithm="HS256",
    )
    resp = client.get("/api/v2/ping", headers={"Authorization": f"Bearer {expired}"})
    assert resp.status_code == 401
    _assert_auth_required(resp.json())


def test_refresh_token_is_rejected_on_protected_route(client: TestClient) -> None:
    login = client.post(
        "/api/v2/auth/login", json={"username": "admin", "password": "secret"}
    ).json()
    refresh = login["data"]["refresh_token"]

    resp = client.get("/api/v2/ping", headers={"Authorization": f"Bearer {refresh}"})
    assert resp.status_code == 401
    _assert_auth_required(resp.json())


def test_wrong_secret_is_rejected(client: TestClient) -> None:
    foreign = pyjwt.encode(
        {
            "sub": "admin",
            "iat": int(time.time()),
            "exp": int(time.time()) + 3600,
            "type": "access",
        },
        "not-the-real-secret",
        algorithm="HS256",
    )
    resp = client.get("/api/v2/ping", headers={"Authorization": f"Bearer {foreign}"})
    assert resp.status_code == 401
    _assert_auth_required(resp.json())


def test_valid_access_token_passes(client: TestClient) -> None:
    login = client.post(
        "/api/v2/auth/login", json={"username": "admin", "password": "secret"}
    ).json()
    access = login["data"]["access_token"]

    resp = client.get("/api/v2/ping", headers={"Authorization": f"Bearer {access}"})
    assert resp.status_code == 200
    assert resp.json() == {"pong": "ok"}


def test_auth_routes_stay_open(client: TestClient) -> None:
    # login/refresh/logout must remain reachable without a token.
    resp = client.post("/api/v2/auth/login", json={"username": "admin", "password": "secret"})
    assert resp.status_code == 200
    resp = client.post("/api/v2/auth/logout")
    assert resp.status_code == 200
