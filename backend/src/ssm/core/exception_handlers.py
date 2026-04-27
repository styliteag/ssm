"""Install FastAPI exception handlers that render the :class:`ApiResponse` envelope."""

from __future__ import annotations

import logging
from http import HTTPStatus
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException

from ssm.core.envelope import ApiResponse
from ssm.core.errors import AppError, ErrorCode

_log = logging.getLogger(__name__)


def _envelope_response(
    *,
    status_code: int,
    code: ErrorCode,
    message: str,
    details: dict[str, Any] | None = None,
) -> JSONResponse:
    body = ApiResponse[Any].fail(code, message, details=details).model_dump(mode="json")
    return JSONResponse(status_code=status_code, content=body)


async def _handle_app_error(_: Request, exc: AppError) -> JSONResponse:
    return _envelope_response(
        status_code=exc.status_code,
        code=exc.code,
        message=exc.message,
        details=exc.details,
    )


async def _handle_validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
    return _envelope_response(
        status_code=HTTPStatus.UNPROCESSABLE_ENTITY,
        code=ErrorCode.VALIDATION_FAILED,
        message="request validation failed",
        details={"errors": exc.errors()},
    )


async def _handle_http_exception(_: Request, exc: HTTPException) -> JSONResponse:
    code = _http_status_to_error_code(exc.status_code)
    message = exc.detail if isinstance(exc.detail, str) else code.value.lower().replace("_", " ")
    return _envelope_response(status_code=exc.status_code, code=code, message=message)


async def _handle_unexpected(_: Request, exc: Exception) -> JSONResponse:
    _log.exception("unhandled exception", exc_info=exc)
    return _envelope_response(
        status_code=HTTPStatus.INTERNAL_SERVER_ERROR,
        code=ErrorCode.INTERNAL_ERROR,
        message="internal server error",
    )


_STATUS_TO_CODE: dict[int, ErrorCode] = {
    HTTPStatus.UNAUTHORIZED: ErrorCode.AUTH_REQUIRED,
    HTTPStatus.FORBIDDEN: ErrorCode.FORBIDDEN,
    HTTPStatus.NOT_FOUND: ErrorCode.HOST_NOT_FOUND,
    HTTPStatus.CONFLICT: ErrorCode.CONFLICT,
    HTTPStatus.UNPROCESSABLE_ENTITY: ErrorCode.VALIDATION_FAILED,
}


def _http_status_to_error_code(status: int) -> ErrorCode:
    return _STATUS_TO_CODE.get(status, ErrorCode.INTERNAL_ERROR)


def install_exception_handlers(app: FastAPI) -> None:
    """Register handlers that render :class:`ApiResponse` for every error path."""
    app.add_exception_handler(AppError, _handle_app_error)  # type: ignore[arg-type]
    app.add_exception_handler(RequestValidationError, _handle_validation_error)  # type: ignore[arg-type]
    app.add_exception_handler(HTTPException, _handle_http_exception)  # type: ignore[arg-type]
    app.add_exception_handler(Exception, _handle_unexpected)
