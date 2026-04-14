// v2 API client: JWT Bearer auth + refresh-on-401 + unwrap<T> helper.

import axios, { AxiosInstance, AxiosRequestConfig, InternalAxiosRequestConfig } from 'axios';

import { ApiResponse, ErrorCode, ErrorInfo, TokenPair } from './types';

const ACCESS_KEY = 'ssm.v2.access_token';
const REFRESH_KEY = 'ssm.v2.refresh_token';

export class ApiError extends Error {
  constructor(
    public readonly code: ErrorCode,
    message: string,
    public readonly details: Record<string, unknown> | null = null,
    public readonly status?: number,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

export const tokenStorage = {
  getAccess: (): string | null => localStorage.getItem(ACCESS_KEY),
  getRefresh: (): string | null => localStorage.getItem(REFRESH_KEY),
  setPair: (pair: TokenPair): void => {
    localStorage.setItem(ACCESS_KEY, pair.access_token);
    localStorage.setItem(REFRESH_KEY, pair.refresh_token);
  },
  clear: (): void => {
    localStorage.removeItem(ACCESS_KEY);
    localStorage.removeItem(REFRESH_KEY);
  },
};

type RefreshCallback = () => Promise<TokenPair | null>;

const createClient = (): AxiosInstance => {
  const baseURL = import.meta.env.VITE_API_URL || '/api/v2';
  const client = axios.create({
    baseURL,
    timeout: 30000,
    headers: { 'Content-Type': 'application/json' },
  });

  client.interceptors.request.use((config: InternalAxiosRequestConfig) => {
    const token = tokenStorage.getAccess();
    const url = config.url || '';
    // Auth endpoints are unauthenticated.
    if (token && !url.startsWith('/auth/')) {
      config.headers.set('Authorization', `Bearer ${token}`);
    }
    return config;
  });

  return client;
};

export const apiClient = createClient();

let refreshInFlight: Promise<TokenPair | null> | null = null;

const refreshOnce = async (): Promise<TokenPair | null> => {
  const refresh = tokenStorage.getRefresh();
  if (!refresh) return null;
  try {
    const resp = await apiClient.post<ApiResponse<TokenPair>>(
      '/auth/refresh',
      { refresh_token: refresh },
      { headers: { Authorization: '' } },
    );
    const pair = resp.data.data;
    if (!pair) return null;
    tokenStorage.setPair(pair);
    return pair;
  } catch {
    tokenStorage.clear();
    return null;
  }
};

export const refreshTokens: RefreshCallback = async () => {
  if (refreshInFlight) return refreshInFlight;
  refreshInFlight = refreshOnce().finally(() => {
    refreshInFlight = null;
  });
  return refreshInFlight;
};

export interface RequestOptions extends AxiosRequestConfig {
  /** If true, do not attempt a silent token refresh on 401. */
  skipRefresh?: boolean;
}

const throwFromEnvelope = <T>(envelope: ApiResponse<T>, status?: number): never => {
  const err: ErrorInfo = envelope.error ?? {
    code: 'INTERNAL_ERROR',
    message: 'unknown error',
    details: null,
  };
  throw new ApiError(err.code, err.message, err.details ?? null, status);
};

async function call<T>(config: RequestOptions): Promise<ApiResponse<T>> {
  try {
    const response = await apiClient.request<ApiResponse<T>>(config);
    return response.data;
  } catch (error: unknown) {
    // Axios error with envelope body: surface as ApiError.
    const ax = error as {
      response?: { data?: ApiResponse<T>; status?: number };
      config?: RequestOptions;
      message?: string;
    };
    const status = ax.response?.status;
    const body = ax.response?.data;

    if (status === 401 && !config.skipRefresh) {
      const pair = await refreshTokens();
      if (pair) {
        return call<T>({ ...config, skipRefresh: true });
      }
    }
    if (body && typeof body === 'object' && 'success' in body) {
      return throwFromEnvelope<T>(body, status);
    }
    throw new ApiError('INTERNAL_ERROR', ax.message ?? 'network error', null, status);
  }
}

export async function unwrap<T>(envelope: ApiResponse<T>): Promise<T> {
  if (envelope.success && envelope.data !== null && envelope.data !== undefined) {
    return envelope.data;
  }
  if (envelope.error) {
    throw new ApiError(envelope.error.code, envelope.error.message, envelope.error.details ?? null);
  }
  throw new ApiError('INTERNAL_ERROR', 'response had no data and no error');
}

export const http = {
  get: <T>(url: string, config?: RequestOptions) =>
    call<T>({ ...config, method: 'GET', url }),
  post: <T>(url: string, data?: unknown, config?: RequestOptions) =>
    call<T>({ ...config, method: 'POST', url, data }),
  patch: <T>(url: string, data?: unknown, config?: RequestOptions) =>
    call<T>({ ...config, method: 'PATCH', url, data }),
  delete: <T>(url: string, config?: RequestOptions) =>
    call<T>({ ...config, method: 'DELETE', url }),
};
