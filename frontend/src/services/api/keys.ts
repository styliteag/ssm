// Keys service — mapped onto /api/v2/keys.

import { api } from './base';
import {
  PublicUserKey,
  KeyFormData,
  PaginatedResponse,
  PaginationQuery,
  ApiResponse,
} from '../../types';

export const keysService = {
  getKeys: async (
    params?: PaginationQuery & { search?: string; user_id?: number },
  ): Promise<ApiResponse<PaginatedResponse<PublicUserKey>>> => {
    const url = params?.user_id !== undefined ? `/keys?user_id=${params.user_id}` : '/keys';
    const response = await api.get<PublicUserKey[]>(url);
    let keys = response.data || [];
    if (params?.search) {
      const q = params.search.toLowerCase();
      keys = keys.filter(
        (k) =>
          (k.key_name || '').toLowerCase().includes(q) ||
          (k.key_base64 || '').toLowerCase().includes(q),
      );
    }
    return {
      success: true,
      data: { items: keys, total: keys.length, page: 1, per_page: keys.length, total_pages: 1 },
    };
  },

  getKey: async (id: number): Promise<ApiResponse<PublicUserKey>> => api.get<PublicUserKey>(`/keys/${id}`),

  createKey: async (userId: number, key: KeyFormData): Promise<ApiResponse<PublicUserKey>> =>
    api.post<PublicUserKey>('/keys', {
      user_id: userId,
      key_type: key.key_type,
      key_base64: key.key_base64,
      name: key.key_name,
      extra_comment: key.extra_comment,
    }),

  updateKey: async (id: number, key: Partial<KeyFormData>): Promise<ApiResponse<PublicUserKey>> =>
    api.patch<PublicUserKey>(`/keys/${id}`, {
      name: key.key_name,
      extra_comment: key.extra_comment,
    }),

  deleteKey: async (id: number): Promise<ApiResponse<null>> => {
    await api.delete<{ deleted_id: number }>(`/keys/${id}`);
    return { success: true, data: null };
  },

  updateKeyName: async (id: number, name: string): Promise<ApiResponse<null>> => {
    await api.patch<unknown>(`/keys/${id}`, { name });
    return { success: true, data: null };
  },

  updateKeyExtraComment: async (id: number, extraComment: string): Promise<ApiResponse<null>> => {
    await api.patch<unknown>(`/keys/${id}`, { extra_comment: extraComment });
    return { success: true, data: null };
  },

  updateKeyComment: async (id: number, comment: string): Promise<ApiResponse<null>> => {
    await api.patch<unknown>(`/keys/${id}`, { name: comment });
    return { success: true, data: null };
  },

  getKeysForUser: async (username: string): Promise<ApiResponse<PublicUserKey[]>> => {
    const users = await api.get<{ id: number; username: string }[]>('/users');
    const match = (users.data || []).find((u) => u.username === username);
    if (!match) return { success: true, data: [] };
    return api.get<PublicUserKey[]>(`/keys?user_id=${match.id}`);
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  parseKey: async (_keyText: string): Promise<ApiResponse<{ key_type: string; key_base64: string; comment?: string }>> => {
    throw new Error('parseKey not available in v2 — parse client-side.');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  validateKey: async (_keyText: string): Promise<ApiResponse<{ valid: boolean; message?: string }>> => {
    throw new Error('validateKey not available in v2 — validate client-side.');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  getKeyFingerprint: async (_keyId: number): Promise<ApiResponse<{ fingerprint: string }>> => {
    throw new Error('getKeyFingerprint not available in v2.');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  importKeys: async (_userId: number, _keysText: string): Promise<ApiResponse<{ imported: number; failed: number; errors?: string[] }>> => {
    throw new Error('importKeys not available in v2.');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  exportKeys: async (_userId: number): Promise<ApiResponse<{ keys_text: string }>> => {
    throw new Error('exportKeys not available in v2.');
  },

  searchKeys: async (query: string): Promise<ApiResponse<PublicUserKey[]>> => {
    const response = await api.get<PublicUserKey[]>('/keys');
    const q = query.toLowerCase();
    return {
      success: true,
      data: (response.data || []).filter((k) => (k.key_name || '').toLowerCase().includes(q)),
    };
  },
};

export default keysService;
