import { api } from './base';
import {
  LoginRequest,
  TokenResponse,
  AuthStatusResponse,
  ApiResponse,
} from '../../types';

export const authService = {
  // Login with username and password
  login: async (credentials: LoginRequest): Promise<ApiResponse<TokenResponse>> => {
    return api.post<TokenResponse>('/auth/login', credentials);
  },

  // Logout current user
  logout: async (): Promise<ApiResponse<null>> => {
    return api.post<null>('/auth/logout');
  },

  // Get current authentication status
  status: async (): Promise<ApiResponse<AuthStatusResponse>> => {
    return api.get<AuthStatusResponse>('/auth/status');
  },

  // Refresh authentication token (if using JWT)
  refresh: async (): Promise<ApiResponse<TokenResponse>> => {
    return api.post<TokenResponse>('/auth/refresh');
  },

  // Check if user is authenticated
  isAuthenticated: (): boolean => {
    const token = localStorage.getItem('auth_token');
    return !!token;
  },

  // Store auth token
  setToken: (token: string): void => {
    localStorage.setItem('auth_token', token);
  },

  // Clear auth token
  clearToken: (): void => {
    localStorage.removeItem('auth_token');
  },

  // Get stored auth token
  getToken: (): string | null => {
    return localStorage.getItem('auth_token');
  },
};

export default authService;