// Authorizations service — mapped onto /api/v2/authorizations.

import { api } from './base';
import {
  Authorization,
  AuthorizationFormData,
  PaginatedResponse,
  PaginationQuery,
  ApiResponse,
} from '../../types';

const resolveHostId = async (name: string): Promise<number> => {
  const list = await api.get<{ id: number; name: string }[]>('/hosts');
  const match = (list.data || []).find((h) => h.name === name);
  if (!match) throw new Error(`Host '${name}' not found`);
  return match.id;
};

const resolveUserId = async (username: string): Promise<number> => {
  const list = await api.get<{ id: number; username: string }[]>('/users');
  const match = (list.data || []).find((u) => u.username === username);
  if (!match) throw new Error(`User '${username}' not found`);
  return match.id;
};

export const authorizationsService = {
  // Dialog helper — v2 has no dedicated dialog endpoint; echo the params back.
  getAuthorizationDialog: async (
    hostName: string,
    username: string,
    login: string,
    options?: string,
  ): Promise<ApiResponse<unknown>> => ({
    success: true,
    data: { host: hostName, user: username, login, options },
  }),

  changeOptions: async (): Promise<ApiResponse<null>> => ({ success: true, data: null }),

  getHostAuthorizations: async (hostName: string): Promise<ApiResponse<Authorization[]>> => {
    const id = await resolveHostId(hostName);
    return api.get<Authorization[]>(`/authorizations?host_id=${id}`);
  },

  getUserAuthorizations: async (username: string): Promise<ApiResponse<Authorization[]>> => {
    const id = await resolveUserId(username);
    return api.get<Authorization[]>(`/authorizations?user_id=${id}`);
  },

  createAuthorization: async (
    authData: AuthorizationFormData,
  ): Promise<ApiResponse<Authorization>> =>
    api.post<Authorization>('/authorizations', {
      host_id: authData.host_id,
      user_id: authData.user_id,
      login: authData.login,
      options: authData.options,
    }),

  deleteAuthorization: async (authId: number): Promise<ApiResponse<null>> => {
    await api.delete<{ deleted_id: number }>(`/authorizations/${authId}`);
    return { success: true, data: null };
  },

  getAuthorizations: async (
    params?: PaginationQuery & { host_id?: number; user_id?: number },
  ): Promise<ApiResponse<PaginatedResponse<Authorization>>> => {
    const qs = new URLSearchParams();
    if (params?.host_id !== undefined) qs.set('host_id', String(params.host_id));
    if (params?.user_id !== undefined) qs.set('user_id', String(params.user_id));
    const url = qs.toString() ? `/authorizations?${qs}` : '/authorizations';
    const response = await api.get<Authorization[]>(url);
    const rows = response.data || [];
    const page = params?.page || 1;
    const perPage = params?.per_page || 50;
    const start = (page - 1) * perPage;
    return {
      success: true,
      data: {
        items: rows.slice(start, start + perPage),
        total: rows.length,
        page,
        per_page: perPage,
        total_pages: Math.ceil(rows.length / perPage) || 1,
      },
    };
  },

  updateAuthorization: async (
    id: number,
    authorization: Partial<AuthorizationFormData>,
    _existingAuth?: Authorization,
  ): Promise<ApiResponse<Authorization>> =>
    api.patch<Authorization>(`/authorizations/${id}`, {
      login: authorization.login,
      options: authorization.options,
      comment: authorization.comment,
    }),

  createBulkAuthorizations: async (
    authorizations: AuthorizationFormData[],
  ): Promise<ApiResponse<{ created: number; failed: number; errors?: string[] }>> => {
    let created = 0;
    let failed = 0;
    const errors: string[] = [];
    for (const a of authorizations) {
      try {
        await api.post<Authorization>('/authorizations', a);
        created++;
      } catch (err) {
        failed++;
        errors.push(`host=${a.host_id} user=${a.user_id}: ${(err as Error).message}`);
      }
    }
    return {
      success: true,
      data: { created, failed, errors: errors.length ? errors : undefined },
    };
  },
};

export default authorizationsService;
