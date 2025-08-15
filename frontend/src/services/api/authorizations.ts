import { api } from './base';
import {
  Authorization,
  AuthorizationFormData,
  PaginatedResponse,
  PaginationQuery,
  ApiResponse,
} from '../../types';

export const authorizationsService = {
  // Get authorization dialog data (for forms)
  getAuthorizationDialog: async (hostName: string, username: string, login: string, options?: string): Promise<ApiResponse<any>> => {
    return api.post<any>('/authorization/dialog_data', {
      host_name: hostName,
      username: username,
      login: login,
      options: options
    });
  },

  // Change authorization options (not implemented in backend yet)
  changeOptions: async (): Promise<ApiResponse<null>> => {
    return api.post<null>('/authorization/change_options');
  },

  // Get authorizations for specific host (use host service method)
  getHostAuthorizations: async (hostName: string): Promise<ApiResponse<Authorization[]>> => {
    const response = await api.get<{ authorizations: Authorization[] }>(`/host/${encodeURIComponent(hostName)}/authorizations`);
    return {
      ...response,
      data: response.data?.authorizations || []
    };
  },

  // Get authorizations for specific user (use user service method)
  getUserAuthorizations: async (username: string): Promise<ApiResponse<Authorization[]>> => {
    const response = await api.get<{ authorizations: Authorization[] }>(`/user/${encodeURIComponent(username)}/authorizations`);
    return {
      ...response,
      data: response.data?.authorizations || []
    };
  },

  // Create authorization (use host service method)
  createAuthorization: async (hostId: number, userId: number, login: string, options?: string): Promise<ApiResponse<Authorization>> => {
    return api.post<Authorization>('/host/user/authorize', {
      host_id: hostId,
      user_id: userId,
      login,
      options
    });
  },

  // Delete authorization (use host service method)
  deleteAuthorization: async (authId: number): Promise<ApiResponse<null>> => {
    return api.delete<null>(`/host/authorization/${authId}`);
  },

  // These methods don't exist in the backend - calling code will need to be updated
  getAuthorizations: async (params?: PaginationQuery & { host_id?: number; user_id?: number }): Promise<ApiResponse<PaginatedResponse<Authorization>>> => {
    throw new Error('getAuthorizations endpoint not available in backend');
  },

  getAuthorization: async (id: number): Promise<ApiResponse<Authorization>> => {
    throw new Error('getAuthorization endpoint not available in backend');
  },

  updateAuthorization: async (id: number, authorization: Partial<AuthorizationFormData>): Promise<ApiResponse<Authorization>> => {
    throw new Error('updateAuthorization endpoint not available in backend');
  },

  createBulkAuthorizations: async (authorizations: AuthorizationFormData[]): Promise<ApiResponse<{ created: number; failed: number; errors?: string[] }>> => {
    throw new Error('createBulkAuthorizations endpoint not available in backend');
  },

  checkAuthorization: async (userId: number, hostId: number): Promise<ApiResponse<{ authorized: boolean; authorization?: Authorization }>> => {
    throw new Error('checkAuthorization endpoint not available in backend');
  },

  copyAuthorizations: async (fromHostId: number, toHostId: number): Promise<ApiResponse<{ copied: number }>> => {
    throw new Error('copyAuthorizations endpoint not available in backend');
  },

  getAuthorizationStats: async (): Promise<ApiResponse<{ total: number; by_host: Record<string, number>; by_user: Record<string, number> }>> => {
    throw new Error('getAuthorizationStats endpoint not available in backend');
  },
};

export default authorizationsService;