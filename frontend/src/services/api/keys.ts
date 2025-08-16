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
    interface BackendKey extends Omit<PublicUserKey, 'comment'> { key_comment?: string; comment?: string; }
    const response = await api.get<{ keys: BackendKey[] }>('/key', { params });
    // Convert to paginated response format expected by frontend and map key_comment to comment
    const keys = (response.data?.keys || []).map((key: BackendKey) => ({
      ...key,
      comment: key.key_comment || key.comment, // Map key_comment from backend to comment field
    }));
    return {
      ...response,
      data: {
        items: keys,
        total: keys.length,
        page: 1,
        per_page: keys.length,
        total_pages: 1
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
    interface BackendKey extends Omit<PublicUserKey, 'comment'> { key_comment?: string; comment?: string; }
    const response = await api.get<{ keys: BackendKey[] }>(`/user/${encodeURIComponent(username)}/keys`);
    // Map key_comment from backend to comment field
    const keys = (response.data?.keys || []).map((key: BackendKey) => ({
      ...key,
      comment: key.key_comment || key.comment,
    }));
    return {
      ...response,
      data: keys
    };
  },

  // These methods don't exist in the backend - calling code will need to be updated
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  getKey: async (_id: number): Promise<ApiResponse<PublicUserKey>> => {
    throw new Error('getKey endpoint not available in backend');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  createKey: async (_userId: number, _key: KeyFormData): Promise<ApiResponse<PublicUserKey>> => {
    throw new Error('createKey endpoint not available in backend. Use usersService.assignKeyToUser instead.');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  updateKey: async (_id: number, _key: Partial<KeyFormData>): Promise<ApiResponse<PublicUserKey>> => {
    throw new Error('updateKey endpoint not available in backend. Use updateKeyComment for comment updates.');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  parseKey: async (_keyText: string): Promise<ApiResponse<{ key_type: string; key_base64: string; comment?: string }>> => {
    throw new Error('parseKey endpoint not available in backend');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  validateKey: async (_keyText: string): Promise<ApiResponse<{ valid: boolean; message?: string }>> => {
    throw new Error('validateKey endpoint not available in backend');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  getKeyFingerprint: async (_keyId: number): Promise<ApiResponse<{ fingerprint: string }>> => {
    throw new Error('getKeyFingerprint endpoint not available in backend');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  importKeys: async (_userId: number, _keysText: string): Promise<ApiResponse<{ imported: number; failed: number; errors?: string[] }>> => {
    throw new Error('importKeys endpoint not available in backend');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  exportKeys: async (_userId: number): Promise<ApiResponse<{ keys_text: string }>> => {
    throw new Error('exportKeys endpoint not available in backend');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  searchKeys: async (_query: string): Promise<ApiResponse<PublicUserKey[]>> => {
    throw new Error('searchKeys endpoint not available in backend');
  },
};

export default keysService;