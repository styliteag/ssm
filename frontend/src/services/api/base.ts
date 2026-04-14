// Axios client against /api/v2 — JWT Bearer + ApiResponse envelope.
//
// Back-compat shape: callers keep receiving { success, data, message } so
// existing pages compile. The v2 envelope's `error.message` is surfaced as
// `message`; `error.code` is attached on thrown errors for code-based branching.

import axios, { AxiosInstance, AxiosRequestConfig, AxiosResponse } from 'axios';

import { ApiResponse } from '../../types';

const ACCESS_TOKEN_KEY = 'ssm.v2.access_token';
const REFRESH_TOKEN_KEY = 'ssm.v2.refresh_token';

interface V2Envelope<T> {
  success: boolean;
  data: T | null;
  error: { code: string; message: string; details: unknown | null } | null;
  meta: Record<string, unknown> | null;
}

export const tokenStore = {
  getAccess: (): string | null => localStorage.getItem(ACCESS_TOKEN_KEY),
  getRefresh: (): string | null => localStorage.getItem(REFRESH_TOKEN_KEY),
  setPair: (access: string, refresh: string): void => {
    localStorage.setItem(ACCESS_TOKEN_KEY, access);
    localStorage.setItem(REFRESH_TOKEN_KEY, refresh);
  },
  clear: (): void => {
    localStorage.removeItem(ACCESS_TOKEN_KEY);
    localStorage.removeItem(REFRESH_TOKEN_KEY);
  },
};

const createApiClient = (): AxiosInstance => {
  const baseURL = import.meta.env.VITE_API_URL || '/api/v2';
  const client = axios.create({
    baseURL,
    timeout: 30000,
    headers: { 'Content-Type': 'application/json' },
  });

  client.interceptors.request.use((config) => {
    const token = tokenStore.getAccess();
    const url = config.url || '';
    if (token && !url.startsWith('/auth/login') && !url.startsWith('/auth/refresh')) {
      config.headers = config.headers || {};
      config.headers['Authorization'] = `Bearer ${token}`;
    }
    return config;
  });

  return client;
};

export const apiClient = createApiClient();

let refreshInFlight: Promise<boolean> | null = null;

const refreshAccessToken = async (): Promise<boolean> => {
  const refresh = tokenStore.getRefresh();
  if (!refresh) return false;
  try {
    const resp = await apiClient.post<V2Envelope<{ access_token: string; refresh_token: string }>>(
      '/auth/refresh',
      { refresh_token: refresh },
    );
    const data = resp.data?.data;
    if (!data) return false;
    tokenStore.setPair(data.access_token, data.refresh_token);
    return true;
  } catch {
    tokenStore.clear();
    return false;
  }
};

const errorToMessage = (err: V2Envelope<unknown>['error']): string =>
  err?.message || 'An API error occurred';

export async function apiRequest<T>(config: AxiosRequestConfig): Promise<ApiResponse<T>> {
  const send = async (): Promise<AxiosResponse<V2Envelope<T>>> => apiClient(config);

  try {
    let response = await send();
    if (response.status === 401 && !(config.url || '').startsWith('/auth/')) {
      if (refreshInFlight === null) refreshInFlight = refreshAccessToken();
      const ok = await refreshInFlight;
      refreshInFlight = null;
      if (ok) response = await send();
    }

    const body = response.data;
    if (body && typeof body === 'object' && 'success' in body) {
      // v2 envelope — repackage into the legacy shape expected by callers.
      if (body.success) {
        return { success: true, data: (body.data ?? undefined) as T | undefined };
      }
      const err = new Error(errorToMessage(body.error)) as Error & { code?: string };
      if (body.error) err.code = body.error.code;
      throw err;
    }
    // Not an envelope — pass the body through.
    return { success: true, data: body as unknown as T };
  } catch (error: unknown) {
    const errorObj = error as {
      response?: { status?: number; data?: V2Envelope<unknown> };
      request?: unknown;
      message?: string;
    };

    if (errorObj.response?.data && typeof errorObj.response.data === 'object' && 'error' in errorObj.response.data) {
      const envErr = errorObj.response.data.error;
      const wrapped = new Error(errorToMessage(envErr)) as Error & { code?: string; status?: number };
      if (envErr?.code) wrapped.code = envErr.code;
      wrapped.status = errorObj.response.status;
      throw wrapped;
    }
    if (errorObj.request) {
      throw new Error('Network error - please check your connection');
    }
    throw new Error(errorObj.message || 'An unexpected error occurred');
  }
}

export const api = {
  get: <T>(url: string, config?: AxiosRequestConfig) => apiRequest<T>({ ...config, method: 'GET', url }),
  post: <T>(url: string, data?: unknown, config?: AxiosRequestConfig) =>
    apiRequest<T>({ ...config, method: 'POST', url, data }),
  put: <T>(url: string, data?: unknown, config?: AxiosRequestConfig) =>
    apiRequest<T>({ ...config, method: 'PUT', url, data }),
  patch: <T>(url: string, data?: unknown, config?: AxiosRequestConfig) =>
    apiRequest<T>({ ...config, method: 'PATCH', url, data }),
  delete: <T>(url: string, config?: AxiosRequestConfig) =>
    apiRequest<T>({ ...config, method: 'DELETE', url }),
};

export default api;
