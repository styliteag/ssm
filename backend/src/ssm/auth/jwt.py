"""JWT issue/verify for access and refresh tokens.

Access tokens last 15 minutes; refresh tokens last 7 days. Both are signed
with HS256 using ``JWT_SECRET``. ``type`` is stored in the payload so a
refresh token can never be used to authenticate a protected request.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from datetime import timedelta
from enum import StrEnum

import jwt as pyjwt

from ssm.core.errors import AppError, AuthRequired

ACCESS_TOKEN_TTL = timedelta(minutes=15)
REFRESH_TOKEN_TTL = timedelta(days=7)
_ALGORITHM = "HS256"


class TokenType(StrEnum):
    ACCESS = "access"
    REFRESH = "refresh"


@dataclass(frozen=True, slots=True)
class TokenClaims:
    sub: str
    iat: int
    exp: int
    type: TokenType


class JwtService:
    """Issue and verify signed access/refresh tokens."""

    def __init__(
        self,
        *,
        secret: str,
        access_ttl: timedelta = ACCESS_TOKEN_TTL,
        refresh_ttl: timedelta = REFRESH_TOKEN_TTL,
    ) -> None:
        if not secret:
            msg = "JWT secret is required"
            raise ValueError(msg)
        self._secret = secret
        self._access_ttl = access_ttl
        self._refresh_ttl = refresh_ttl

    def issue_access(self, subject: str) -> str:
        return self._issue(subject, TokenType.ACCESS, self._access_ttl)

    def issue_refresh(self, subject: str) -> str:
        return self._issue(subject, TokenType.REFRESH, self._refresh_ttl)

    def verify(self, token: str, *, expected_type: TokenType) -> TokenClaims:
        try:
            payload = pyjwt.decode(token, self._secret, algorithms=[_ALGORITHM])
        except pyjwt.PyJWTError as exc:
            raise AuthRequired(f"invalid token: {exc}") from exc

        try:
            claims = TokenClaims(
                sub=str(payload["sub"]),
                iat=int(payload["iat"]),
                exp=int(payload["exp"]),
                type=TokenType(payload["type"]),
            )
        except (KeyError, ValueError) as exc:
            raise AuthRequired("token payload is malformed") from exc

        if claims.type is not expected_type:
            raise AuthRequired(f"expected {expected_type.value} token")
        return claims

    def _issue(self, subject: str, token_type: TokenType, ttl: timedelta) -> str:
        if not subject:
            msg = "subject must not be empty"
            raise ValueError(msg)
        now = int(time.time())
        payload: dict[str, object] = {
            "sub": subject,
            "iat": now,
            "exp": now + int(ttl.total_seconds()),
            "type": token_type.value,
        }
        return pyjwt.encode(payload, self._secret, algorithm=_ALGORITHM)


# Suppress unused-import warnings for mypy/IDEs.
_ = AppError
