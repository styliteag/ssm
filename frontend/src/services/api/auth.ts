import { api } from './base';
import {
  LoginRequest,
  TokenResponse,
  ApiResponse,
} from '../../types';
import { setCsrfToken, clearCsrfToken } from '../csrf';

export const authService = {
  // Login with username and password (session-based auth)
  login: async (credentials: LoginRequest): Promise<ApiResponse<{ success: boolean; username: string; message: string; csrf_token: string }>> => {
    const response = await api.post<{ success: boolean; username: string; message: string; csrf_token: string }>('/auth/login', credentials);
    // Store CSRF token on successful login
    if (response.data?.csrf_token) {
      setCsrfToken(response.data.csrf_token);
    }
    return response;
  },

  // Logout current user
  logout: async (): Promise<ApiResponse<null>> => {
    const response = await api.post<null>('/auth/logout');
    // Clear CSRF token on logout
    clearCsrfToken();
    return response;
  },

  // Get current authentication status
  status: async (): Promise<ApiResponse<{ logged_in: boolean; username?: string }>> => {
    return api.get<{ logged_in: boolean; username?: string }>('/auth/status');
  },

  // Check if user is authenticated (using session-based auth via cookies)
  isAuthenticated: async (): Promise<boolean> => {
    try {
      const response = await authService.status();
      return response.data?.logged_in || false;
    } catch {
      return false;
    }
  },

  // Session-based auth doesn't use tokens stored in localStorage
  // These methods are kept for backwards compatibility but don't do anything meaningful
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  setToken: (_token: string): void => {
    // No-op for session-based auth
    console.warn('setToken called but session-based auth does not use tokens');
  },

  clearToken: (): void => {
    // No-op for session-based auth
    console.warn('clearToken called but session-based auth does not use tokens');
  },

  getToken: (): string | null => {
    // No-op for session-based auth
    console.warn('getToken called but session-based auth does not use tokens');
    return null;
  },

  // Refresh not needed for session-based auth
  refresh: async (): Promise<ApiResponse<TokenResponse>> => {
    throw new Error('Refresh not available with session-based authentication');
  },

  // Get CSRF token from server
  getCsrfToken: async (): Promise<ApiResponse<{ csrf_token: string }>> => {
    const response = await api.get<{ csrf_token: string }>('/auth/csrf');
    if (response.data?.csrf_token) {
      setCsrfToken(response.data.csrf_token);
    }
    return response;
  },
};

export default authService;