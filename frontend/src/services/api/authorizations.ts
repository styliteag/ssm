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
  createAuthorization: async (authData: AuthorizationFormData): Promise<ApiResponse<Authorization>> => {
    return api.post<Authorization>('/host/user/authorize', {
      host_id: authData.host_id,
      user_id: authData.user_id,
      login: authData.login,
      options: authData.options
    });
  },

  // Delete authorization (use host service method)
  deleteAuthorization: async (authId: number): Promise<ApiResponse<null>> => {
    return api.delete<null>(`/host/authorization/${authId}`);
  },

  // Get all authorizations by fetching from all users
  getAuthorizations: async (params?: PaginationQuery & { host_id?: number; user_id?: number }): Promise<ApiResponse<PaginatedResponse<Authorization>>> => {
    try {
      // Get all users first
      const usersResponse = await api.get<any[]>('/user');
      if (!usersResponse.success || !usersResponse.data) {
        return { success: false, message: 'Failed to fetch users' };
      }

      const users = usersResponse.data;
      const allAuthorizations: Authorization[] = [];

      // Get authorizations for each user
      for (const user of users) {
        try {
          const userAuthResponse = await api.get<{ authorizations: Authorization[] }>(`/user/${encodeURIComponent(user.username)}/authorizations`);
          if (userAuthResponse.success && userAuthResponse.data) {
            allAuthorizations.push(...userAuthResponse.data.authorizations);
          }
        } catch (error) {
          // Continue with other users if one fails
          console.warn(`Failed to get authorizations for user ${user.username}:`, error);
        }
      }

      // Apply filters if provided
      let filteredAuthorizations = allAuthorizations;
      if (params?.host_id) {
        filteredAuthorizations = filteredAuthorizations.filter(auth => auth.host_id === params.host_id);
      }
      if (params?.user_id) {
        filteredAuthorizations = filteredAuthorizations.filter(auth => auth.user_id === params.user_id);
      }

      // Apply pagination
      const page = params?.page || 1;
      const perPage = params?.per_page || 50;
      const startIndex = (page - 1) * perPage;
      const endIndex = startIndex + perPage;
      const paginatedItems = filteredAuthorizations.slice(startIndex, endIndex);

      return {
        success: true,
        data: {
          items: paginatedItems,
          total: filteredAuthorizations.length,
          page: page,
          per_page: perPage,
          total_pages: Math.ceil(filteredAuthorizations.length / perPage)
        }
      };
    } catch (error) {
      console.error('Error fetching authorizations:', error);
      return { success: false, message: 'Failed to fetch authorizations' };
    }
  },

  getAuthorization: async (id: number): Promise<ApiResponse<Authorization>> => {
    throw new Error('getAuthorization endpoint not available in backend');
  },

  updateAuthorization: async (id: number, authorization: Partial<AuthorizationFormData>): Promise<ApiResponse<Authorization>> => {
    // Update not directly supported, but we can delete and recreate
    // For now, return an error to indicate this needs special handling
    throw new Error('Update not supported - delete and recreate authorization instead');
  },

  createBulkAuthorizations: async (authorizations: AuthorizationFormData[]): Promise<ApiResponse<{ created: number; failed: number; errors?: string[] }>> => {
    let created = 0;
    let failed = 0;
    const errors: string[] = [];

    for (const authData of authorizations) {
      try {
        const response = await api.post<Authorization>('/host/user/authorize', {
          host_id: authData.host_id,
          user_id: authData.user_id,
          login: authData.login,
          options: authData.options
        });
        if (response.success) {
          created++;
        } else {
          failed++;
          errors.push(`Failed to create authorization for user ${authData.user_id} on host ${authData.host_id}: ${response.message}`);
        }
      } catch (error) {
        failed++;
        errors.push(`Error creating authorization for user ${authData.user_id} on host ${authData.host_id}: ${error}`);
      }
    }

    return {
      success: true,
      data: { created, failed, errors: errors.length > 0 ? errors : undefined }
    };
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