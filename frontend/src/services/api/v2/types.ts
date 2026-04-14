// v2 envelope + domain types (mirrors Pydantic models in backend/src/ssm).

export type ErrorCode =
  | 'AUTH_REQUIRED'
  | 'INVALID_CREDENTIALS'
  | 'FORBIDDEN'
  | 'VALIDATION_FAILED'
  | 'HOST_NOT_FOUND'
  | 'USER_NOT_FOUND'
  | 'KEY_NOT_FOUND'
  | 'AUTHORIZATION_NOT_FOUND'
  | 'HOST_DISABLED'
  | 'SSH_READONLY'
  | 'SSH_CONNECT_FAILED'
  | 'CONFLICT'
  | 'INTERNAL_ERROR';

export interface ErrorInfo {
  code: ErrorCode;
  message: string;
  details?: Record<string, unknown> | null;
}

export interface Meta {
  total?: number | null;
  page?: number | null;
  page_size?: number | null;
}

export interface ApiResponse<T> {
  success: boolean;
  data: T | null;
  error: ErrorInfo | null;
  meta: Meta | null;
}

export interface TokenPair {
  access_token: string;
  refresh_token: string;
  token_type: string;
}

export interface Me {
  username: string;
}

export interface Host {
  id: number;
  name: string;
  username: string;
  address: string;
  port: number;
  key_fingerprint: string | null;
  jump_via: number | null;
  disabled: boolean;
  comment: string | null;
}

export interface User {
  id: number;
  username: string;
  enabled: boolean;
  comment: string | null;
}

export interface UserKey {
  id: number;
  user_id: number;
  key_type: string;
  key_base64: string;
  name: string | null;
  extra_comment: string | null;
}

export interface Authorization {
  id: number;
  host_id: number;
  user_id: number;
  login: string;
  options: string | null;
  comment: string | null;
}

export type DiffStatus = 'present' | 'missing_on_host' | 'extra_on_host';

export interface KeyDiff {
  status: DiffStatus;
  line: string;
}

export interface LoginDiff {
  login: string;
  read_error: string | null;
  items: KeyDiff[];
}

export interface HostDiff {
  host_id: number;
  host_name: string;
  disabled: boolean;
  logins: LoginDiff[];
}

export interface SyncedLogin {
  login: string;
  written_keys: number;
}

export interface SyncResult {
  host_id: number;
  host_name: string;
  logins: SyncedLogin[];
}

export interface ActivityLogEntry {
  id: number;
  activity_type: string;
  action: string;
  target: string;
  user_id: number | null;
  actor_username: string;
  timestamp: number;
  meta: string | null;
}
