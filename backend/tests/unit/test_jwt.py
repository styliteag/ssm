"""Tests for ssm.auth.jwt — access + refresh token issue/verify."""

from __future__ import annotations

import time
from datetime import timedelta

import jwt as pyjwt
import pytest

from ssm.auth.jwt import (
    ACCESS_TOKEN_TTL,
    REFRESH_TOKEN_TTL,
    JwtService,
    TokenClaims,
    TokenType,
)
from ssm.core.errors import AppError, ErrorCode

SECRET = "unit-test-secret"


def _svc(**kwargs: object) -> JwtService:
    return JwtService(secret=SECRET, **kwargs)  # type: ignore[arg-type]


def test_access_token_default_ttl_is_15m() -> None:
    assert timedelta(minutes=15) == ACCESS_TOKEN_TTL


def test_refresh_token_default_ttl_is_7d() -> None:
    assert timedelta(days=7) == REFRESH_TOKEN_TTL


def test_issue_and_verify_access_token_roundtrip() -> None:
    svc = _svc()
    token = svc.issue_access("alice")
    claims = svc.verify(token, expected_type=TokenType.ACCESS)

    assert claims.sub == "alice"
    assert claims.type is TokenType.ACCESS
    assert claims.exp > claims.iat
    assert claims.exp - claims.iat == int(ACCESS_TOKEN_TTL.total_seconds())


def test_issue_refresh_token_has_long_ttl() -> None:
    svc = _svc()
    token = svc.issue_refresh("alice")
    claims = svc.verify(token, expected_type=TokenType.REFRESH)

    assert claims.type is TokenType.REFRESH
    assert claims.exp - claims.iat == int(REFRESH_TOKEN_TTL.total_seconds())


def test_verify_rejects_wrong_type() -> None:
    svc = _svc()
    access = svc.issue_access("alice")

    with pytest.raises(AppError) as exc_info:
        svc.verify(access, expected_type=TokenType.REFRESH)
    assert exc_info.value.code is ErrorCode.AUTH_REQUIRED


def test_verify_rejects_wrong_signature() -> None:
    svc = _svc()
    token = svc.issue_access("alice")
    other = JwtService(secret="different-secret")

    with pytest.raises(AppError) as exc_info:
        other.verify(token, expected_type=TokenType.ACCESS)
    assert exc_info.value.code is ErrorCode.AUTH_REQUIRED


def test_verify_rejects_expired_token() -> None:
    now = int(time.time())
    svc = _svc()
    # Manually craft an expired token so we don't rely on timers.
    token = pyjwt.encode(
        {"sub": "alice", "iat": now - 3600, "exp": now - 60, "type": "access"},
        SECRET,
        algorithm="HS256",
    )

    with pytest.raises(AppError) as exc_info:
        svc.verify(token, expected_type=TokenType.ACCESS)
    assert exc_info.value.code is ErrorCode.AUTH_REQUIRED


def test_verify_rejects_malformed_token() -> None:
    svc = _svc()
    with pytest.raises(AppError) as exc_info:
        svc.verify("not-a-jwt", expected_type=TokenType.ACCESS)
    assert exc_info.value.code is ErrorCode.AUTH_REQUIRED


def test_verify_rejects_empty_subject() -> None:
    svc = _svc()
    with pytest.raises(ValueError):
        svc.issue_access("")


def test_token_claims_frozen() -> None:
    c = TokenClaims(sub="x", iat=1, exp=2, type=TokenType.ACCESS)
    with pytest.raises((AttributeError, TypeError)):
        c.sub = "y"  # type: ignore[misc]


def test_custom_ttls_are_respected() -> None:
    svc = JwtService(
        secret=SECRET,
        access_ttl=timedelta(seconds=30),
        refresh_ttl=timedelta(hours=1),
    )
    access = svc.verify(svc.issue_access("u"), expected_type=TokenType.ACCESS)
    refresh = svc.verify(svc.issue_refresh("u"), expected_type=TokenType.REFRESH)

    assert access.exp - access.iat == 30
    assert refresh.exp - refresh.iat == 3600


def test_different_subjects_get_different_tokens() -> None:
    svc = _svc()
    assert svc.issue_access("alice") != svc.issue_access("bob")


def test_secret_is_required() -> None:
    with pytest.raises(ValueError):
        JwtService(secret="")
