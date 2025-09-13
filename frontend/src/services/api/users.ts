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

export const usersService = {
  // Get paginated list of users
  getUsers: async (params?: PaginationQuery & { search?: string; enabled?: boolean }): Promise<ApiResponse<PaginatedResponse<User>>> => {
    // Backend returns array directly, not paginated
    const response = await api.get<User[]>('/user', { params });
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

  // Get single user by username (backend uses username, not ID)
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  getUser: async (_id: number): Promise<ApiResponse<User>> => {
    throw new Error('getUser by ID not supported. Use getUserByUsername instead.');
  },

  // Get user by username (this is what the backend actually supports)
  getUserByUsername: async (username: string): Promise<ApiResponse<User>> => {
    return api.get<User>(`/user/${encodeURIComponent(username)}`);
  },

  // Create new user
  createUser: async (user: UserFormData): Promise<ApiResponse<User>> => {
    return api.post<User>('/user', user);
  },

  // Update existing user by username
  updateUser: async (oldUsername: string, user: UserFormData): Promise<ApiResponse<User>> => {
    return api.put<User>(`/user/${encodeURIComponent(oldUsername)}`, {
      username: user.username,
      enabled: user.enabled,
      comment: user.comment
    });
  },

  // Delete user by username
  deleteUser: async (username: string): Promise<ApiResponse<null>> => {
    return api.delete<null>(`/user/${encodeURIComponent(username)}`);
  },

  // Get user authorizations by username
  getUserAuthorizations: async (username: string): Promise<ApiResponse<Authorization[]>> => {
    const response = await api.get<{ authorizations: Authorization[] }>(`/user/${encodeURIComponent(username)}/authorizations`);
    return {
      ...response,
      data: response.data?.authorizations || []
    };
  },

  // Get user SSH keys by username
  getUserKeys: async (username: string): Promise<ApiResponse<PublicUserKey[]>> => {
    const response = await api.get<{ keys: PublicUserKey[] }>(`/user/${encodeURIComponent(username)}/keys`);
    return {
      ...response,
      data: response.data?.keys || []
    };
  },

  // Assign key to user
  assignKeyToUser: async (keyData: {
    user_id: number;
    key_type: string;
    key_base64: string;
    key_name: string | null;
    extra_comment: string | null;
  }): Promise<ApiResponse<null>> => {
    console.log('assignKeyToUser called with:', keyData);
    return api.post<null>('/user/assign_key', keyData);
  },

  // Add key dialog (preview key before assignment)
  previewKey: async (keyData: {
    key_type: string;
    key_base64: string;
    key_name?: string;
    extra_comment?: string;
  }): Promise<ApiResponse<unknown>> => {
    return api.post<unknown>('/user/add_key', keyData);
  },

  // Get all users (for dropdowns, etc.)
  getAllUsers: async (): Promise<ApiResponse<User[]>> => {
    return api.get<User[]>('/user');
  },

  // These methods don't exist in backend - calling code will need to be updated
  getEnabledUsers: async (): Promise<ApiResponse<User[]>> => {
    // Filter enabled users on frontend since backend doesn't have this endpoint
    const response = await api.get<User[]>('/user');
    const data = response.data || [];
    return {
      ...response,
      data: data.filter(user => user.enabled)
    };
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  toggleUser: async (_id: number, _enabled: boolean): Promise<ApiResponse<User>> => {
    throw new Error('toggleUser endpoint not available in backend. Use updateUser instead.');
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  searchUsers: async (_query: string): Promise<ApiResponse<User[]>> => {
    throw new Error('searchUsers endpoint not available in backend');
  },
};

export default usersService;