import { api } from './base';
import {
  User,
  UserFormData,
  PaginatedResponse,
  PaginationQuery,
  ApiResponse,
  Authorization,
  PublicUserKey,
} from '../../types';

export const usersService = {
  // Get paginated list of users
  getUsers: async (params?: PaginationQuery & { search?: string; enabled?: boolean }): Promise<ApiResponse<PaginatedResponse<User>>> => {
    return api.get<PaginatedResponse<User>>('/users', { params });
  },

  // Get single user by ID
  getUser: async (id: number): Promise<ApiResponse<User>> => {
    return api.get<User>(`/users/${id}`);
  },

  // Create new user
  createUser: async (user: UserFormData): Promise<ApiResponse<User>> => {
    return api.post<User>('/users', user);
  },

  // Update existing user
  updateUser: async (id: number, user: UserFormData): Promise<ApiResponse<User>> => {
    return api.put<User>(`/users/${id}`, user);
  },

  // Delete user
  deleteUser: async (id: number): Promise<ApiResponse<null>> => {
    return api.delete<null>(`/users/${id}`);
  },

  // Enable/disable user
  toggleUser: async (id: number, enabled: boolean): Promise<ApiResponse<User>> => {
    return api.patch<User>(`/users/${id}/toggle`, { enabled });
  },

  // Get user authorizations
  getUserAuthorizations: async (id: number): Promise<ApiResponse<Authorization[]>> => {
    return api.get<Authorization[]>(`/users/${id}/authorizations`);
  },

  // Get user SSH keys
  getUserKeys: async (id: number): Promise<ApiResponse<PublicUserKey[]>> => {
    return api.get<PublicUserKey[]>(`/users/${id}/keys`);
  },

  // Get all users (for dropdowns, etc.)
  getAllUsers: async (): Promise<ApiResponse<User[]>> => {
    return api.get<User[]>('/users/all');
  },

  // Get enabled users only
  getEnabledUsers: async (): Promise<ApiResponse<User[]>> => {
    return api.get<User[]>('/users/enabled');
  },

  // Get user by username
  getUserByUsername: async (username: string): Promise<ApiResponse<User>> => {
    return api.get<User>(`/users/username/${encodeURIComponent(username)}`);
  },

  // Search users by name
  searchUsers: async (query: string): Promise<ApiResponse<User[]>> => {
    return api.get<User[]>('/users/search', { params: { q: query } });
  },
};

export default usersService;