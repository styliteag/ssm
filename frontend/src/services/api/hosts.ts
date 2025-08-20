import { api } from './base';
import {
  Host,
  PaginatedResponse,
  PaginationQuery,
  ApiResponse,
  Authorization,
  AllowedUserOnHost,
} from '../../types';

export const hostsService = {
  // Get paginated list of hosts
  getHosts: async (params?: PaginationQuery & { search?: string }): Promise<ApiResponse<PaginatedResponse<Host>>> => {
    // Backend returns array directly, not paginated
    const response = await api.get<Host[]>('/host', { params });
    // Convert to paginated response format expected by frontend
    const data = response.data || [];
    return {
      ...response,
      data: {
        items: data,
        total: data.length,
        page: 1,
        per_page: data.length,
        total_pages: 1
      }
    };
  },

  // Get single host by name (backend uses name, not ID)
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  getHost: async (_id: number): Promise<ApiResponse<Host>> => {
    throw new Error('getHost by ID not supported. Use getHostByName instead.');
  },

  // Get host by name (this is what the backend actually supports)
  getHostByName: async (name: string): Promise<ApiResponse<Host>> => {
    return api.get<Host>(`/host/${encodeURIComponent(name)}`);
  },

  // Create new host
  createHost: async (host: Partial<Host> & { key_fingerprint?: string }): Promise<ApiResponse<Host & { requires_confirmation?: boolean; key_fingerprint?: string }>> => {
    return api.post<Host & { requires_confirmation?: boolean; key_fingerprint?: string }>('/host', host);
  },

  // Update existing host by name
  updateHost: async (name: string, host: Partial<Host>): Promise<ApiResponse<Host>> => {
    return api.put<Host>(`/host/${encodeURIComponent(name)}`, host);
  },

  // Delete host by name
  deleteHost: async (name: string): Promise<ApiResponse<null>> => {
    return api.delete<null>(`/host/${encodeURIComponent(name)}`);
  },

  // Get host authorizations by name
  getHostAuthorizations: async (name: string): Promise<ApiResponse<Authorization[]>> => {
    return api.get<Authorization[]>(`/host/${encodeURIComponent(name)}/authorizations`);
  },

  // Add authorization to host (backend uses different endpoint structure)
  addHostAuthorization: async (hostId: number, authorization: Omit<Authorization, 'id' | 'host_id'>): Promise<ApiResponse<Authorization>> => {
    return api.post<Authorization>('/host/user/authorize', {
      host_id: hostId,
      user_id: authorization.user_id,
      login: authorization.login,
      options: authorization.options
    });
  },

  // Remove authorization (backend uses different endpoint)
  removeHostAuthorization: async (authId: number): Promise<ApiResponse<null>> => {
    return api.delete<null>(`/host/authorization/${authId}`);
  },

  // Get logins for host
  getHostLogins: async (name: string, forceUpdate?: boolean): Promise<ApiResponse<string[]>> => {
    const params = forceUpdate ? { force_update: true } : undefined;
    const response = await api.get<{ logins: string[] }>(`/host/${encodeURIComponent(name)}/logins`, { params });
    return {
      ...response,
      data: response.data?.logins || []
    };
  },

  // Add host key
  addHostKey: async (_id: number, keyFingerprint?: string): Promise<ApiResponse<unknown>> => {
    return api.post<unknown>(`/host/${_id}/add_hostkey`, { key_fingerprint: keyFingerprint });
  },

  // Generate authorized keys
  generateAuthorizedKeys: async (hostName: string, login: string): Promise<ApiResponse<unknown>> => {
    return api.post<unknown>('/host/gen_authorized_keys', { host_name: hostName, login });
  },

  // Set authorized keys on host
  setAuthorizedKeys: async (hostName: string, login: string, authorizedKeys: string): Promise<ApiResponse<null>> => {
    return api.post<null>(`/host/${encodeURIComponent(hostName)}/set_authorized_keys`, {
      login,
      authorized_keys: authorizedKeys
    });
  },

  // Legacy methods for backwards compatibility - these will need to be updated in calling code
  getAllHosts: async (): Promise<ApiResponse<Host[]>> => {
    return api.get<Host[]>('/host');
  },

  // These methods don't exist in backend - calling code will need to be updated
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  getAllowedUsers: async (_id: number): Promise<ApiResponse<AllowedUserOnHost[]>> => {
    throw new Error('getAllowedUsers endpoint not available in backend');
  },

  // Test connection by attempting to get logins (requires SSH connectivity)
  testConnection: async (hostName: string): Promise<ApiResponse<{ success: boolean; message: string }>> => {
    try {
      const response = await api.get<{ logins: string[] }>(`/host/${encodeURIComponent(hostName)}/logins`);
      if (response.success) {
        return {
          ...response,
          data: {
            success: true,
            message: `Connection successful. Found ${response.data?.logins?.length || 0} available logins.`
          }
        };
      } else {
        return {
          ...response,
          data: {
            success: false,
            message: response.message || 'Connection failed'
          }
        };
      }
    } catch (error: any) {
      // Extract error message from API response if available
      let errorMessage = 'Connection failed';
      if (error?.response?.data?.message) {
        errorMessage = error.response.data.message;
      } else if (error?.message) {
        errorMessage = error.message;
      }

      return {
        success: false,
        message: errorMessage,
        data: {
          success: false,
          message: errorMessage
        }
      };
    }
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  deployKeys: async (_id: number): Promise<ApiResponse<{ message: string }>> => {
    throw new Error('deployKeys endpoint not available in backend');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  getKeyDifferences: async (_id: number): Promise<ApiResponse<unknown>> => {
    throw new Error('getKeyDifferences endpoint not available in backend');
  },
};

export default hostsService;