// Hosts service — mapped onto /api/v2/hosts + /api/v2/diffs.
//
// Kept same function names so existing pages compile without changes.

import { api } from './base';
import {
  Host,
  PaginatedResponse,
  PaginationQuery,
  ApiResponse,
  Authorization,
  AllowedUserOnHost,
} from '../../types';

type IdOrName = number | string;

const resolveHostId = async (idOrName: IdOrName): Promise<number> => {
  if (typeof idOrName === 'number') return idOrName;
  const asInt = Number(idOrName);
  if (!Number.isNaN(asInt) && String(asInt) === idOrName) return asInt;
  const list = await api.get<Host[]>('/hosts');
  const match = (list.data || []).find((h) => h.name === idOrName);
  if (!match) throw new Error(`Host '${idOrName}' not found`);
  return match.id;
};

export const hostsService = {
  getHosts: async (
    params?: PaginationQuery & { search?: string },
  ): Promise<ApiResponse<PaginatedResponse<Host>>> => {
    const response = await api.get<Host[]>('/hosts', { params });
    const rows = response.data || [];
    const q = params?.search?.toLowerCase() || '';
    const filtered = q ? rows.filter((h) => h.name.toLowerCase().includes(q)) : rows;
    return {
      success: true,
      data: {
        items: filtered,
        total: filtered.length,
        page: 1,
        per_page: filtered.length,
        total_pages: 1,
      },
    };
  },

  getHost: async (id: number): Promise<ApiResponse<Host>> => api.get<Host>(`/hosts/${id}`),

  getHostByName: async (name: string): Promise<ApiResponse<Host>> => {
    const id = await resolveHostId(name);
    return api.get<Host>(`/hosts/${id}`);
  },

  createHost: async (
    host: Partial<Host> & { key_fingerprint?: string },
  ): Promise<ApiResponse<Host & { requires_confirmation?: boolean; key_fingerprint?: string }>> => {
    return api.post<Host & { requires_confirmation?: boolean; key_fingerprint?: string }>(
      '/hosts',
      host,
    );
  },

  updateHost: async (nameOrId: IdOrName, host: Partial<Host>): Promise<ApiResponse<Host>> => {
    const id = await resolveHostId(nameOrId);
    return api.patch<Host>(`/hosts/${id}`, host);
  },

  deleteHost: async (nameOrId: IdOrName): Promise<ApiResponse<null>> => {
    const id = await resolveHostId(nameOrId);
    await api.delete<{ deleted_id: number }>(`/hosts/${id}`);
    return { success: true, data: null };
  },

  getHostAuthorizations: async (nameOrId: IdOrName): Promise<ApiResponse<Authorization[]>> => {
    const id = await resolveHostId(nameOrId);
    return api.get<Authorization[]>(`/authorizations?host_id=${id}`);
  },

  addHostAuthorization: async (
    hostId: number,
    authorization: Omit<Authorization, 'id' | 'host_id'>,
  ): Promise<ApiResponse<Authorization>> => {
    return api.post<Authorization>('/authorizations', {
      host_id: hostId,
      user_id: authorization.user_id,
      login: authorization.login,
      options: authorization.options,
      comment: authorization.comment,
    });
  },

  removeHostAuthorization: async (authId: number): Promise<ApiResponse<null>> => {
    await api.delete<{ deleted_id: number }>(`/authorizations/${authId}`);
    return { success: true, data: null };
  },

  // v2 doesn't enumerate remote login accounts; derive logins from authorizations.
  getHostLogins: async (
    nameOrId: IdOrName,
    _forceUpdate?: boolean,
  ): Promise<ApiResponse<string[]>> => {
    const id = await resolveHostId(nameOrId);
    const resp = await api.get<Authorization[]>(`/authorizations?host_id=${id}`);
    const logins = Array.from(new Set((resp.data || []).map((a) => a.login)));
    return { success: true, data: logins };
  },

  // Hostkey fingerprint confirmation flow — not in v2; kept as a no-op success.
  addHostKey: async (
    _id: number,
    _keyFingerprint?: string,
  ): Promise<ApiResponse<unknown>> => ({ success: true, data: null }),

  // Get a rendered authorized_keys preview via the v2 diff endpoint.
  generateAuthorizedKeys: async (
    hostName: string,
    _login: string,
  ): Promise<ApiResponse<unknown>> => {
    const id = await resolveHostId(hostName);
    return api.get<unknown>(`/diffs/${id}`);
  },

  // In v2 sync rewrites ALL logins; for a single login, sync everything.
  setAuthorizedKeys: async (
    hostName: string,
    _login: string,
    _authorizedKeys: string,
  ): Promise<ApiResponse<null>> => {
    const id = await resolveHostId(hostName);
    await api.post<unknown>(`/diffs/${id}/sync`);
    return { success: true, data: null };
  },

  getAllHosts: async (): Promise<ApiResponse<Host[]>> => api.get<Host[]>('/hosts'),

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  getAllowedUsers: async (_id: number): Promise<ApiResponse<AllowedUserOnHost[]>> => {
    throw new Error('getAllowedUsers endpoint not available in v2');
  },

  // v2 CachingSshClient exposes this server-side; no remote trigger today.
  invalidateCache: async (_hostName: string): Promise<ApiResponse<{ message: string }>> => ({
    success: true,
    data: { message: 'cache invalidation is server-side only in v2' },
  }),

  testConnection: async (
    hostName: string,
  ): Promise<ApiResponse<{ success: boolean; message: string }>> => {
    try {
      const id = await resolveHostId(hostName);
      const resp = await api.get<unknown>(`/diffs/${id}`);
      const ok = resp.success !== false;
      return {
        success: true,
        data: { success: ok, message: ok ? 'Connection successful.' : 'Connection failed.' },
      };
    } catch (error: unknown) {
      const message = (error as Error)?.message || 'Connection failed';
      return { success: false, message, data: { success: false, message } };
    }
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  deployKeys: async (id: number): Promise<ApiResponse<{ message: string }>> => {
    await api.post<unknown>(`/diffs/${id}/sync`);
    return { success: true, data: { message: 'synced' } };
  },

  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  getKeyDifferences: async (id: number): Promise<ApiResponse<unknown>> => api.get<unknown>(`/diffs/${id}`),
};

export default hostsService;
