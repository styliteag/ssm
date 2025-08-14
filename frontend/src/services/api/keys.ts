import { api } from './base';
import {
  PublicUserKey,
  KeyFormData,
  PaginatedResponse,
  PaginationQuery,
  ApiResponse,
} from '../../types';

export const keysService = {
  // Get paginated list of keys
  getKeys: async (params?: PaginationQuery & { search?: string; user_id?: number }): Promise<ApiResponse<PaginatedResponse<PublicUserKey>>> => {
    return api.get<PaginatedResponse<PublicUserKey>>('/keys', { params });
  },

  // Get single key by ID
  getKey: async (id: number): Promise<ApiResponse<PublicUserKey>> => {
    return api.get<PublicUserKey>(`/keys/${id}`);
  },

  // Create new SSH key for user
  createKey: async (userId: number, key: KeyFormData): Promise<ApiResponse<PublicUserKey>> => {
    return api.post<PublicUserKey>(`/users/${userId}/keys`, key);
  },

  // Update existing key
  updateKey: async (id: number, key: Partial<KeyFormData>): Promise<ApiResponse<PublicUserKey>> => {
    return api.put<PublicUserKey>(`/keys/${id}`, key);
  },

  // Delete SSH key
  deleteKey: async (id: number): Promise<ApiResponse<null>> => {
    return api.delete<null>(`/keys/${id}`);
  },

  // Parse SSH key from text format
  parseKey: async (keyText: string): Promise<ApiResponse<{ key_type: string; key_base64: string; comment?: string }>> => {
    return api.post<{ key_type: string; key_base64: string; comment?: string }>('/keys/parse', { key_text: keyText });
  },

  // Validate SSH key format
  validateKey: async (keyText: string): Promise<ApiResponse<{ valid: boolean; message?: string }>> => {
    return api.post<{ valid: boolean; message?: string }>('/keys/validate', { key_text: keyText });
  },

  // Get key fingerprint
  getKeyFingerprint: async (keyId: number): Promise<ApiResponse<{ fingerprint: string }>> => {
    return api.get<{ fingerprint: string }>(`/keys/${keyId}/fingerprint`);
  },

  // Get all keys for a user
  getKeysForUser: async (userId: number): Promise<ApiResponse<PublicUserKey[]>> => {
    return api.get<PublicUserKey[]>(`/users/${userId}/keys`);
  },

  // Import multiple keys from text (one per line)
  importKeys: async (userId: number, keysText: string): Promise<ApiResponse<{ imported: number; failed: number; errors?: string[] }>> => {
    return api.post<{ imported: number; failed: number; errors?: string[] }>(`/users/${userId}/keys/import`, { keys_text: keysText });
  },

  // Export user's keys in OpenSSH format
  exportKeys: async (userId: number): Promise<ApiResponse<{ keys_text: string }>> => {
    return api.get<{ keys_text: string }>(`/users/${userId}/keys/export`);
  },

  // Search keys by comment or content
  searchKeys: async (query: string): Promise<ApiResponse<PublicUserKey[]>> => {
    return api.get<PublicUserKey[]>('/keys/search', { params: { q: query } });
  },
};

export default keysService;