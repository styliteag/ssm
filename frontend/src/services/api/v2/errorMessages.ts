// Map backend ErrorCode → user-facing message.
//
// Callers that used to branch on an error's free-form ``message`` should
// switch to ``ApiError.code`` (stable) and render via :func:`describeError`.

import { ApiError } from './base';
import { ErrorCode } from './types';

const HUMAN: Record<ErrorCode, string> = {
  AUTH_REQUIRED: 'Please log in to continue.',
  INVALID_CREDENTIALS: 'Invalid username or password.',
  FORBIDDEN: "You don't have permission to perform this action.",
  VALIDATION_FAILED: 'Some fields are invalid — please review and try again.',
  HOST_NOT_FOUND: 'Host not found.',
  USER_NOT_FOUND: 'User not found.',
  KEY_NOT_FOUND: 'SSH key not found.',
  AUTHORIZATION_NOT_FOUND: 'Authorization not found.',
  HOST_DISABLED: 'This host is disabled; enable it before continuing.',
  SSH_READONLY: 'This host is read-only; writes are not permitted right now.',
  SSH_CONNECT_FAILED: 'Could not reach the host over SSH.',
  CONFLICT: 'That change conflicts with existing data.',
  INTERNAL_ERROR: 'Something went wrong on the server.',
};

export function describeError(error: unknown): string {
  if (error instanceof ApiError) {
    return HUMAN[error.code] ?? error.message;
  }
  if (error instanceof Error) {
    return error.message;
  }
  return 'An unexpected error occurred.';
}

/** Predicate helper for branching logic in components. */
export function isApiErrorCode(error: unknown, code: ErrorCode): boolean {
  return error instanceof ApiError && error.code === code;
}
