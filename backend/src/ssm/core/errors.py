"""Error codes and domain exception hierarchy.

Every public-facing failure has a stable, string-valued ``ErrorCode`` so the
frontend can branch on it instead of parsing free-form messages.
"""

from __future__ import annotations

from enum import StrEnum
from typing import Any


class ErrorCode(StrEnum):
    """Stable error codes surfaced to API clients."""

    AUTH_REQUIRED = "AUTH_REQUIRED"
    INVALID_CREDENTIALS = "INVALID_CREDENTIALS"
    FORBIDDEN = "FORBIDDEN"
    VALIDATION_FAILED = "VALIDATION_FAILED"

    HOST_NOT_FOUND = "HOST_NOT_FOUND"
    USER_NOT_FOUND = "USER_NOT_FOUND"
    KEY_NOT_FOUND = "KEY_NOT_FOUND"
    AUTHORIZATION_NOT_FOUND = "AUTHORIZATION_NOT_FOUND"

    HOST_DISABLED = "HOST_DISABLED"
    SSH_READONLY = "SSH_READONLY"
    SSH_CONNECT_FAILED = "SSH_CONNECT_FAILED"

    CONFLICT = "CONFLICT"
    INTERNAL_ERROR = "INTERNAL_ERROR"


class AppError(Exception):
    """Base class for domain exceptions that translate to ``ApiResponse`` errors."""

    def __init__(
        self,
        code: ErrorCode,
        message: str,
        *,
        status_code: int = 400,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code
        self.details = details


class AuthRequired(AppError):
    def __init__(self, message: str = "authentication required") -> None:
        super().__init__(ErrorCode.AUTH_REQUIRED, message, status_code=401)


class InvalidCredentials(AppError):
    def __init__(self, message: str = "invalid credentials") -> None:
        super().__init__(ErrorCode.INVALID_CREDENTIALS, message, status_code=401)


class Forbidden(AppError):
    def __init__(self, message: str = "forbidden") -> None:
        super().__init__(ErrorCode.FORBIDDEN, message, status_code=403)


class ValidationFailed(AppError):
    def __init__(self, message: str, *, details: dict[str, Any] | None = None) -> None:
        super().__init__(ErrorCode.VALIDATION_FAILED, message, status_code=422, details=details)


class HostNotFound(AppError):
    def __init__(self, message: str = "host not found") -> None:
        super().__init__(ErrorCode.HOST_NOT_FOUND, message, status_code=404)


class UserNotFound(AppError):
    def __init__(self, message: str = "user not found") -> None:
        super().__init__(ErrorCode.USER_NOT_FOUND, message, status_code=404)


class KeyNotFound(AppError):
    def __init__(self, message: str = "key not found") -> None:
        super().__init__(ErrorCode.KEY_NOT_FOUND, message, status_code=404)


class AuthorizationNotFound(AppError):
    def __init__(self, message: str = "authorization not found") -> None:
        super().__init__(ErrorCode.AUTHORIZATION_NOT_FOUND, message, status_code=404)


class HostDisabled(AppError):
    def __init__(self, message: str = "host is disabled") -> None:
        super().__init__(ErrorCode.HOST_DISABLED, message, status_code=409)


class SshReadOnly(AppError):
    def __init__(self, message: str = "host is marked read-only") -> None:
        super().__init__(ErrorCode.SSH_READONLY, message, status_code=409)


class SshConnectFailed(AppError):
    def __init__(self, message: str = "ssh connection failed") -> None:
        super().__init__(ErrorCode.SSH_CONNECT_FAILED, message, status_code=502)


class Conflict(AppError):
    def __init__(self, message: str = "resource conflict") -> None:
        super().__init__(ErrorCode.CONFLICT, message, status_code=409)
