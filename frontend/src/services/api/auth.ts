// v2 JWT auth — login issues access+refresh, stored in localStorage by base.ts.

import { api, tokenStore } from './base';
import { ApiResponse, LoginRequest } from '../../types';

interface TokenPair {
  access_token: string;
  refresh_token: string;
  token_type: string;
}

interface MeResponse {
  username: string;
}

export const authService = {
  login: async (
    credentials: LoginRequest,
  ): Promise<ApiResponse<{ username: string }>> => {
    const resp = await api.post<TokenPair>('/auth/login', credentials);
    const pair = resp.data;
    if (!pair) {
      return { success: false, message: 'login failed' };
    }
    tokenStore.setPair(pair.access_token, pair.refresh_token);
    return { success: true, data: { username: credentials.username } };
  },

  logout: async (): Promise<ApiResponse<null>> => {
    try {
      await api.post<{ logged_out: boolean }>('/auth/logout');
    } finally {
      tokenStore.clear();
    }
    return { success: true, data: null };
  },

  status: async (): Promise<ApiResponse<{ logged_in: boolean; username?: string }>> => {
    if (!tokenStore.getAccess()) {
      return { success: true, data: { logged_in: false } };
    }
    try {
      const resp = await api.get<MeResponse>('/auth/me');
      const username = resp.data?.username;
      return { success: true, data: { logged_in: !!username, username } };
    } catch {
      return { success: true, data: { logged_in: false } };
    }
  },

  isAuthenticated: async (): Promise<boolean> => {
    const resp = await authService.status();
    return resp.data?.logged_in || false;
  },

  setToken: (token: string): void => {
    localStorage.setItem('ssm.v2.access_token', token);
  },

  clearToken: (): void => {
    tokenStore.clear();
  },

  getToken: (): string | null => tokenStore.getAccess(),

  refresh: async (): Promise<ApiResponse<{ token: string; expires_in: number }>> => {
    const refresh = tokenStore.getRefresh();
    if (!refresh) throw new Error('no refresh token');
    const resp = await api.post<TokenPair>('/auth/refresh', { refresh_token: refresh });
    const pair = resp.data;
    if (!pair) throw new Error('refresh failed');
    tokenStore.setPair(pair.access_token, pair.refresh_token);
    return { success: true, data: { token: pair.access_token, expires_in: 900 } };
  },
};

export default authService;
