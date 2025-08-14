import { api } from './base';
import {
  Authorization,
  AuthorizationFormData,
  PaginatedResponse,
  PaginationQuery,
  ApiResponse,
} from '../../types';

export const authorizationsService = {
  // Get paginated list of authorizations
  getAuthorizations: async (params?: PaginationQuery & { host_id?: number; user_id?: number }): Promise<ApiResponse<PaginatedResponse<Authorization>>> => {
    return api.get<PaginatedResponse<Authorization>>('/authorizations', { params });
  },

  // Get single authorization by ID
  getAuthorization: async (id: number): Promise<ApiResponse<Authorization>> => {
    return api.get<Authorization>(`/authorizations/${id}`);
  },

  // Create new authorization
  createAuthorization: async (authorization: AuthorizationFormData): Promise<ApiResponse<Authorization>> => {
    return api.post<Authorization>('/authorizations', authorization);
  },

  // Update existing authorization
  updateAuthorization: async (id: number, authorization: Partial<AuthorizationFormData>): Promise<ApiResponse<Authorization>> => {
    return api.put<Authorization>(`/authorizations/${id}`, authorization);
  },

  // Delete authorization
  deleteAuthorization: async (id: number): Promise<ApiResponse<null>> => {
    return api.delete<null>(`/authorizations/${id}`);
  },

  // Get authorizations for specific host
  getHostAuthorizations: async (hostId: number): Promise<ApiResponse<Authorization[]>> => {
    return api.get<Authorization[]>(`/hosts/${hostId}/authorizations`);
  },

  // Get authorizations for specific user
  getUserAuthorizations: async (userId: number): Promise<ApiResponse<Authorization[]>> => {
    return api.get<Authorization[]>(`/users/${userId}/authorizations`);
  },

  // Bulk create authorizations
  createBulkAuthorizations: async (authorizations: AuthorizationFormData[]): Promise<ApiResponse<{ created: number; failed: number; errors?: string[] }>> => {
    return api.post<{ created: number; failed: number; errors?: string[] }>('/authorizations/bulk', { authorizations });
  },

  // Check if user is authorized for host
  checkAuthorization: async (userId: number, hostId: number): Promise<ApiResponse<{ authorized: boolean; authorization?: Authorization }>> => {
    return api.get<{ authorized: boolean; authorization?: Authorization }>(`/authorizations/check`, {
      params: { user_id: userId, host_id: hostId }
    });
  },

  // Get authorization dialog data (for forms)
  getAuthorizationDialog: async (hostId?: number, userId?: number): Promise<ApiResponse<{ hosts: any[]; users: any[] }>> => {
    return api.get<{ hosts: any[]; users: any[] }>('/authorizations/dialog', {
      params: { host_id: hostId, user_id: userId }
    });
  },

  // Copy authorizations from one host to another
  copyAuthorizations: async (fromHostId: number, toHostId: number): Promise<ApiResponse<{ copied: number }>> => {
    return api.post<{ copied: number }>('/authorizations/copy', {
      from_host_id: fromHostId,
      to_host_id: toHostId
    });
  },

  // Get authorization summary statistics
  getAuthorizationStats: async (): Promise<ApiResponse<{ total: number; by_host: Record<string, number>; by_user: Record<string, number> }>> => {
    return api.get<{ total: number; by_host: Record<string, number>; by_user: Record<string, number> }>('/authorizations/stats');
  },
};

export default authorizationsService;