"""Tests for ssm.core.envelope — ApiResponse[T] + ErrorInfo + Meta."""

from __future__ import annotations

from pydantic import BaseModel

from ssm.core.envelope import ApiResponse, ErrorInfo, Meta
from ssm.core.errors import ErrorCode


class Widget(BaseModel):
    id: int
    name: str


def test_success_response_shape() -> None:
    resp = ApiResponse[Widget].ok(Widget(id=1, name="a"))

    assert resp.success is True
    assert resp.data is not None
    assert resp.data.id == 1
    assert resp.data.name == "a"
    assert resp.error is None
    assert resp.meta is None


def test_error_response_shape() -> None:
    resp: ApiResponse[Widget] = ApiResponse[Widget].fail(
        ErrorCode.HOST_NOT_FOUND, "host 42 does not exist"
    )

    assert resp.success is False
    assert resp.data is None
    assert resp.error is not None
    assert resp.error.code is ErrorCode.HOST_NOT_FOUND
    assert resp.error.message == "host 42 does not exist"
    assert resp.meta is None


def test_success_with_meta() -> None:
    resp = ApiResponse[list[Widget]].ok(
        [Widget(id=1, name="a"), Widget(id=2, name="b")],
        meta=Meta(total=2, page=1, page_size=50),
    )

    assert resp.success is True
    assert resp.meta is not None
    assert resp.meta.total == 2
    assert resp.meta.page == 1
    assert resp.meta.page_size == 50


def test_envelope_serializes_error_code_as_string_enum() -> None:
    resp: ApiResponse[Widget] = ApiResponse[Widget].fail(ErrorCode.AUTH_REQUIRED, "login required")
    payload = resp.model_dump(mode="json")

    assert payload["success"] is False
    assert payload["data"] is None
    assert payload["error"] == {
        "code": "AUTH_REQUIRED",
        "message": "login required",
        "details": None,
    }
    assert payload["meta"] is None


def test_error_info_supports_details() -> None:
    err = ErrorInfo(
        code=ErrorCode.VALIDATION_FAILED,
        message="invalid payload",
        details={"field": "port", "reason": "must be > 0"},
    )

    assert err.details == {"field": "port", "reason": "must be > 0"}
