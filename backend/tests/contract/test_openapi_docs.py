"""Contract tests confirming the OpenAPI document and Swagger UI are wired up."""

from __future__ import annotations

from fastapi.testclient import TestClient


def test_openapi_json_is_served_under_v2(auth_client: TestClient) -> None:
    resp = auth_client.get("/api/v2/openapi.json")
    assert resp.status_code == 200
    doc = resp.json()

    # OpenAPI 3 document shape.
    assert doc["openapi"].startswith("3.")
    assert doc["info"]["title"] == "ssm"
    assert doc["info"]["version"] == "2.0.0"


def test_openapi_document_covers_every_router(auth_client: TestClient) -> None:
    doc = auth_client.get("/api/v2/openapi.json").json()
    paths = set(doc["paths"].keys())

    expected = {
        "/api/v2/auth/login",
        "/api/v2/auth/refresh",
        "/api/v2/auth/logout",
        "/api/v2/auth/me",
        "/api/v2/hosts",
        "/api/v2/hosts/{host_id}",
        "/api/v2/users",
        "/api/v2/users/{user_id}",
        "/api/v2/keys",
        "/api/v2/keys/{key_id}",
        "/api/v2/authorizations",
        "/api/v2/authorizations/{auth_id}",
        "/api/v2/diffs/{host_id}",
        "/api/v2/diffs/{host_id}/sync",
        "/api/v2/activity-log",
    }

    missing = expected - paths
    assert not missing, f"missing OpenAPI paths: {missing}"


def test_swagger_ui_is_served(auth_client: TestClient) -> None:
    resp = auth_client.get("/api/v2/docs")
    assert resp.status_code == 200
    assert "text/html" in resp.headers.get("content-type", "")
    body = resp.text.lower()
    assert "swagger" in body
    # The Swagger UI HTML references the v2 openapi document.
    assert "/api/v2/openapi.json" in resp.text
