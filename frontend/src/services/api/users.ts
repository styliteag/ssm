// Users service — mapped onto /api/v2/users + /api/v2/keys + /api/v2/authorizations.

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

const resolveUserId = async (idOrName: number | string): Promise<number> => {
  if (typeof idOrName === 'number') return idOrName;
  const asInt = Number(idOrName);
  if (!Number.isNaN(asInt) && String(asInt) === idOrName) return asInt;
  const list = await api.get<User[]>('/users');
  const match = (list.data || []).find((u) => u.username === idOrName);
  if (!match) throw new Error(`User '${idOrName}' not found`);
  return match.id;
};

export const usersService = {
  getUsers: async (
    params?: PaginationQuery & { search?: string; enabled?: boolean },
  ): Promise<ApiResponse<PaginatedResponse<User>>> => {
    const response = await api.get<User[]>('/users');
    let data = response.data || [];
    if (params?.search) {
      const q = params.search.toLowerCase();
      data = data.filter((u) => u.username.toLowerCase().includes(q));
    }
    if (params?.enabled !== undefined) data = data.filter((u) => u.enabled === params.enabled);
    return {
      success: true,
      data: { items: data, total: data.length, page: 1, per_page: data.length, total_pages: 1 },
    };
  },

  getUser: async (id: number): Promise<ApiResponse<User>> => api.get<User>(`/users/${id}`),

  getUserByUsername: async (username: string): Promise<ApiResponse<User>> => {
    const id = await resolveUserId(username);
    return api.get<User>(`/users/${id}`);
  },

  createUser: async (user: UserFormData): Promise<ApiResponse<User>> => api.post<User>('/users', user),

  updateUser: async (oldUsername: string, user: UserFormData): Promise<ApiResponse<User>> => {
    const id = await resolveUserId(oldUsername);
    return api.patch<User>(`/users/${id}`, {
      username: user.username,
      enabled: user.enabled,
      comment: user.comment,
    });
  },

  deleteUser: async (username: string): Promise<ApiResponse<null>> => {
    const id = await resolveUserId(username);
    await api.delete<{ deleted_id: number }>(`/users/${id}`);
    return { success: true, data: null };
  },

  getUserAuthorizations: async (username: string): Promise<ApiResponse<Authorization[]>> => {
    const id = await resolveUserId(username);
    return api.get<Authorization[]>(`/authorizations?user_id=${id}`);
  },

  getUserKeys: async (username: string): Promise<ApiResponse<PublicUserKey[]>> => {
    const id = await resolveUserId(username);
    return api.get<PublicUserKey[]>(`/keys?user_id=${id}`);
  },

  assignKeyToUser: async (keyData: {
    user_id: number;
    key_type: string;
    key_base64: string;
    key_name: string | null;
    extra_comment: string | null;
  }): Promise<ApiResponse<null>> => {
    await api.post<unknown>('/keys', {
      user_id: keyData.user_id,
      key_type: keyData.key_type,
      key_base64: keyData.key_base64,
      name: keyData.key_name,
      extra_comment: keyData.extra_comment,
    });
    return { success: true, data: null };
  },

  previewKey: async (keyData: {
    key_type: string;
    key_base64: string;
    key_name?: string;
    extra_comment?: string;
  }): Promise<ApiResponse<unknown>> => {
    // No preview endpoint in v2 — echo the input so the UI can render it.
    return { success: true, data: keyData };
  },

  getAllUsers: async (): Promise<ApiResponse<User[]>> => api.get<User[]>('/users'),

  getEnabledUsers: async (): Promise<ApiResponse<User[]>> => {
    const response = await api.get<User[]>('/users');
    return { success: true, data: (response.data || []).filter((u) => u.enabled) };
  },

  toggleUser: async (id: number, enabled: boolean): Promise<ApiResponse<User>> =>
    api.patch<User>(`/users/${id}`, { enabled }),

  searchUsers: async (query: string): Promise<ApiResponse<User[]>> => {
    const response = await api.get<User[]>('/users');
    const q = query.toLowerCase();
    return {
      success: true,
      data: (response.data || []).filter((u) => u.username.toLowerCase().includes(q)),
    };
  },
};

export default usersService;
