"""``ApiResponse[T]`` envelope used for every v2 response.

Shape: ``{success: bool, data: T | None, error: ErrorInfo | None, meta: Meta | None}``.
Frontends decide on ``error.code`` (a stable ``ErrorCode`` enum) rather than
parsing ``error.message``.
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel, ConfigDict

from ssm.core.errors import ErrorCode


class ErrorInfo(BaseModel):
    """Failure payload inside an :class:`ApiResponse`."""

    model_config = ConfigDict(use_enum_values=False)

    code: ErrorCode
    message: str
    details: dict[str, Any] | None = None


class Meta(BaseModel):
    """Pagination / list metadata for envelope responses."""

    total: int | None = None
    page: int | None = None
    page_size: int | None = None


class ApiResponse[T](BaseModel):
    """Uniform response envelope."""

    model_config = ConfigDict(use_enum_values=False)

    success: bool
    data: T | None = None
    error: ErrorInfo | None = None
    meta: Meta | None = None

    @classmethod
    def ok(cls, data: T, *, meta: Meta | None = None) -> ApiResponse[T]:
        return cls(success=True, data=data, error=None, meta=meta)

    @classmethod
    def fail(
        cls,
        code: ErrorCode,
        message: str,
        *,
        details: dict[str, Any] | None = None,
    ) -> ApiResponse[T]:
        return cls(
            success=False,
            data=None,
            error=ErrorInfo(code=code, message=message, details=details),
            meta=None,
        )
