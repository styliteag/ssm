import { api } from './base';
import {
  Host,
  HostFormData,
  PaginatedResponse,
  PaginationQuery,
  ApiResponse,
  Authorization,
  AllowedUserOnHost,
} from '../../types';

export const hostsService = {
  // Get paginated list of hosts
  getHosts: async (params?: PaginationQuery & { search?: string }): Promise<ApiResponse<PaginatedResponse<Host>>> => {
    return api.get<PaginatedResponse<Host>>('/hosts', { params });
  },

  // Get single host by ID
  getHost: async (id: number): Promise<ApiResponse<Host>> => {
    return api.get<Host>(`/hosts/${id}`);
  },

  // Create new host
  createHost: async (host: HostFormData): Promise<ApiResponse<Host>> => {
    return api.post<Host>('/hosts', host);
  },

  // Update existing host
  updateHost: async (id: number, host: HostFormData): Promise<ApiResponse<Host>> => {
    return api.put<Host>(`/hosts/${id}`, host);
  },

  // Delete host
  deleteHost: async (id: number): Promise<ApiResponse<null>> => {
    return api.delete<null>(`/hosts/${id}`);
  },

  // Get host authorizations
  getHostAuthorizations: async (id: number): Promise<ApiResponse<Authorization[]>> => {
    return api.get<Authorization[]>(`/hosts/${id}/authorizations`);
  },

  // Add authorization to host
  addHostAuthorization: async (hostId: number, authorization: Omit<Authorization, 'id' | 'host_id'>): Promise<ApiResponse<Authorization>> => {
    return api.post<Authorization>(`/hosts/${hostId}/authorizations`, authorization);
  },

  // Remove authorization from host
  removeHostAuthorization: async (hostId: number, authId: number): Promise<ApiResponse<null>> => {
    return api.delete<null>(`/hosts/${hostId}/authorizations/${authId}`);
  },

  // Get allowed users on host (for diff/keys view)
  getAllowedUsers: async (id: number): Promise<ApiResponse<AllowedUserOnHost[]>> => {
    return api.get<AllowedUserOnHost[]>(`/hosts/${id}/allowed-users`);
  },

  // Test SSH connection to host
  testConnection: async (id: number): Promise<ApiResponse<{ success: boolean; message: string }>> => {
    return api.post<{ success: boolean; message: string }>(`/hosts/${id}/test-connection`);
  },

  // Deploy keys to host
  deployKeys: async (id: number): Promise<ApiResponse<{ message: string }>> => {
    return api.post<{ message: string }>(`/hosts/${id}/deploy`);
  },

  // Get host key differences (what would be deployed)
  getKeyDifferences: async (id: number): Promise<ApiResponse<any>> => {
    return api.get<any>(`/hosts/${id}/diff`);
  },

  // Get all hosts (for dropdowns, etc.)
  getAllHosts: async (): Promise<ApiResponse<Host[]>> => {
    return api.get<Host[]>('/hosts/all');
  },

  // Get host by name
  getHostByName: async (name: string): Promise<ApiResponse<Host>> => {
    return api.get<Host>(`/hosts/name/${encodeURIComponent(name)}`);
  },
};

export default hostsService;