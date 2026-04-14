"""Tests for exception → ApiResponse envelope mapping in a FastAPI app."""

from __future__ import annotations

from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic import BaseModel

from ssm.core.errors import AppError, AuthRequired, ErrorCode, HostNotFound, ValidationFailed
from ssm.core.exception_handlers import install_exception_handlers


class Echo(BaseModel):
    value: int


def _make_app() -> FastAPI:
    app = FastAPI()
    install_exception_handlers(app)

    @app.get("/raises/auth")
    def raises_auth() -> None:
        raise AuthRequired("you must log in")

    @app.get("/raises/notfound")
    def raises_notfound() -> None:
        raise HostNotFound("host missing")

    @app.get("/raises/validation")
    def raises_validation() -> None:
        raise ValidationFailed("bad", details={"field": "port"})

    @app.get("/raises/generic")
    def raises_generic() -> None:
        raise AppError(ErrorCode.INTERNAL_ERROR, "something", status_code=500)

    @app.get("/raises/unexpected")
    def raises_unexpected() -> None:
        raise RuntimeError("boom")

    @app.post("/echo")
    def echo(body: Echo) -> dict[str, int]:
        return {"value": body.value}

    return app


def test_auth_required_returns_envelope_with_401() -> None:
    client = TestClient(_make_app())
    resp = client.get("/raises/auth")

    assert resp.status_code == 401
    body = resp.json()
    assert body["success"] is False
    assert body["data"] is None
    assert body["error"]["code"] == "AUTH_REQUIRED"
    assert body["error"]["message"] == "you must log in"


def test_not_found_returns_envelope_with_404() -> None:
    client = TestClient(_make_app())
    resp = client.get("/raises/notfound")

    assert resp.status_code == 404
    body = resp.json()
    assert body["error"]["code"] == "HOST_NOT_FOUND"


def test_validation_failed_returns_details() -> None:
    client = TestClient(_make_app())
    resp = client.get("/raises/validation")

    assert resp.status_code == 422
    body = resp.json()
    assert body["error"]["code"] == "VALIDATION_FAILED"
    assert body["error"]["details"] == {"field": "port"}


def test_pydantic_validation_becomes_validation_failed() -> None:
    client = TestClient(_make_app())
    resp = client.post("/echo", json={"value": "not an int"})

    assert resp.status_code == 422
    body = resp.json()
    assert body["success"] is False
    assert body["error"]["code"] == "VALIDATION_FAILED"
    assert body["error"]["details"] is not None


def test_unexpected_exception_becomes_internal_error() -> None:
    client = TestClient(_make_app(), raise_server_exceptions=False)
    resp = client.get("/raises/unexpected")

    assert resp.status_code == 500
    body = resp.json()
    assert body["success"] is False
    assert body["error"]["code"] == "INTERNAL_ERROR"
    # Do not leak the exception message verbatim.
    assert "boom" not in body["error"]["message"]
