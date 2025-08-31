import axios, { AxiosInstance, AxiosRequestConfig, AxiosResponse } from 'axios';
import { ApiResponse, ApiError } from '../../types';
import { getCsrfToken } from '../csrf';

// Create axios instance with default config
const createApiClient = (): AxiosInstance => {
  const baseURL = import.meta.env.VITE_API_URL || '/api';
  
  const client = axios.create({
    baseURL,
    timeout: 10000,
    headers: {
      'Content-Type': 'application/json',
    },
    withCredentials: true, // Include cookies for session-based auth
  });

  // Request interceptor to add CSRF token for ALL API requests
  client.interceptors.request.use(
    (config) => {
      const url = config.url || '';
      
      // Add CSRF token for all API requests except auth endpoints
      if (!url.startsWith('/auth/')) {
        const token = getCsrfToken();
        if (token) {
          config.headers['X-CSRF-Token'] = token;
        }
      }
      return config;
    },
    (error) => Promise.reject(error)
  );

  // Response interceptor for error handling
  client.interceptors.response.use(
    (response) => response,
    (error) => {
      if (error.response?.status === 401) {
        // Handle unauthorized access - redirect to login
        window.location.href = '/login';
      }
      return Promise.reject(error);
    }
  );

  return client;
};

export const apiClient = createApiClient();

// Generic API request handler
export async function apiRequest<T>(
  config: AxiosRequestConfig
): Promise<ApiResponse<T>> {
  try {
    const response: AxiosResponse<ApiResponse<T>> = await apiClient(config);
    return response.data;
  } catch (error: unknown) {
    // Handle axios errors and API errors
    const errorObj = error as { response?: { data?: ApiError }; request?: unknown; message?: string };
    
    if (errorObj.response?.data) {
      const apiError: ApiError = errorObj.response.data;
      throw new Error(apiError.message || 'An API error occurred');
    }
    
    if (errorObj.request) {
      throw new Error('Network error - please check your connection');
    }
    
    throw new Error(errorObj.message || 'An unexpected error occurred');
  }
}

// HTTP method helpers
export const api = {
  get: <T>(url: string, config?: AxiosRequestConfig) =>
    apiRequest<T>({ ...config, method: 'GET', url }),

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