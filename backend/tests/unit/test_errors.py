"""Tests for ssm.core.errors — enum values + AppError hierarchy."""

from __future__ import annotations

from ssm.core.errors import (
    AppError,
    AuthRequired,
    ErrorCode,
    HostDisabled,
    HostNotFound,
    SshReadOnly,
    ValidationFailed,
)


def test_error_code_values_are_stable_strings() -> None:
    assert ErrorCode.AUTH_REQUIRED.value == "AUTH_REQUIRED"
    assert ErrorCode.HOST_DISABLED.value == "HOST_DISABLED"
    assert ErrorCode.HOST_NOT_FOUND.value == "HOST_NOT_FOUND"
    assert ErrorCode.SSH_READONLY.value == "SSH_READONLY"
    assert ErrorCode.VALIDATION_FAILED.value == "VALIDATION_FAILED"
    assert ErrorCode.INTERNAL_ERROR.value == "INTERNAL_ERROR"


def test_app_error_carries_code_and_status() -> None:
    err = AuthRequired("login please")
    assert isinstance(err, AppError)
    assert err.code is ErrorCode.AUTH_REQUIRED
    assert err.status_code == 401
    assert str(err) == "login please"


def test_host_disabled_status() -> None:
    err = HostDisabled("host 'x' is disabled")
    assert err.code is ErrorCode.HOST_DISABLED
    assert err.status_code == 409


def test_host_not_found_status() -> None:
    err = HostNotFound("host 7 not found")
    assert err.code is ErrorCode.HOST_NOT_FOUND
    assert err.status_code == 404


def test_ssh_readonly_status() -> None:
    err = SshReadOnly("readonly sentinel present")
    assert err.code is ErrorCode.SSH_READONLY
    assert err.status_code == 409


def test_validation_failed_carries_details() -> None:
    err = ValidationFailed("bad payload", details={"field": "port"})
    assert err.code is ErrorCode.VALIDATION_FAILED
    assert err.status_code == 422
    assert err.details == {"field": "port"}
