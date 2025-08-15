import { api } from './base';
import {
  PublicUserKey,
  KeyFormData,
  PaginatedResponse,
  PaginationQuery,
  ApiResponse,
} from '../../types';

export const keysService = {
  // Get paginated list of all keys
  getKeys: async (params?: PaginationQuery & { search?: string; user_id?: number }): Promise<ApiResponse<PaginatedResponse<PublicUserKey>>> => {
    // Backend returns wrapped response with keys array
    const response = await api.get<{ keys: PublicUserKey[] }>('/key', { params });
    // Convert to paginated response format expected by frontend
    const keys = response.data?.keys || [];
    return {
      ...response,
      data: {
        items: keys,
        total: keys.length,
        page: 1,
        per_page: keys.length,
        last_page: 1
      }
    };
  },

  // Delete SSH key by ID
  deleteKey: async (id: number): Promise<ApiResponse<null>> => {
    return api.delete<null>(`/key/${id}`);
  },

  // Update key comment
  updateKeyComment: async (id: number, comment: string): Promise<ApiResponse<null>> => {
    return api.put<null>(`/key/${id}/comment`, { comment });
  },

  // Get all keys for a user (use the user service method instead)
  getKeysForUser: async (username: string): Promise<ApiResponse<PublicUserKey[]>> => {
    const response = await api.get<{ keys: PublicUserKey[] }>(`/user/${encodeURIComponent(username)}/keys`);
    return {
      ...response,
      data: response.data?.keys || []
    };
  },

  // These methods don't exist in the backend - calling code will need to be updated
  getKey: async (id: number): Promise<ApiResponse<PublicUserKey>> => {
    throw new Error('getKey endpoint not available in backend');
  },

  createKey: async (userId: number, key: KeyFormData): Promise<ApiResponse<PublicUserKey>> => {
    throw new Error('createKey endpoint not available in backend. Use usersService.assignKeyToUser instead.');
  },

  updateKey: async (id: number, key: Partial<KeyFormData>): Promise<ApiResponse<PublicUserKey>> => {
    throw new Error('updateKey endpoint not available in backend. Use updateKeyComment for comment updates.');
  },

  parseKey: async (keyText: string): Promise<ApiResponse<{ key_type: string; key_base64: string; comment?: string }>> => {
    throw new Error('parseKey endpoint not available in backend');
  },

  validateKey: async (keyText: string): Promise<ApiResponse<{ valid: boolean; message?: string }>> => {
    throw new Error('validateKey endpoint not available in backend');
  },

  getKeyFingerprint: async (keyId: number): Promise<ApiResponse<{ fingerprint: string }>> => {
    throw new Error('getKeyFingerprint endpoint not available in backend');
  },

  importKeys: async (userId: number, keysText: string): Promise<ApiResponse<{ imported: number; failed: number; errors?: string[] }>> => {
    throw new Error('importKeys endpoint not available in backend');
  },

  exportKeys: async (userId: number): Promise<ApiResponse<{ keys_text: string }>> => {
    throw new Error('exportKeys endpoint not available in backend');
  },

  searchKeys: async (query: string): Promise<ApiResponse<PublicUserKey[]>> => {
    throw new Error('searchKeys endpoint not available in backend');
  },
};

export default keysService;