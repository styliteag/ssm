import { http, unwrap } from './base';
import { Authorization } from './types';

export interface CreateAuthorizationRequest {
  host_id: number;
  user_id: number;
  login: string;
  options?: string | null;
  comment?: string | null;
}

export interface UpdateAuthorizationRequest {
  login?: string;
  options?: string | null;
  comment?: string | null;
}

export interface ListAuthorizationsFilter {
  host_id?: number;
  user_id?: number;
}

const qs = (f: ListAuthorizationsFilter): string => {
  const params = new URLSearchParams();
  if (f.host_id !== undefined) params.set('host_id', String(f.host_id));
  if (f.user_id !== undefined) params.set('user_id', String(f.user_id));
  const s = params.toString();
  return s ? `?${s}` : '';
};

export const authorizationsApi = {
  list: async (filter: ListAuthorizationsFilter = {}): Promise<Authorization[]> =>
    unwrap(await http.get<Authorization[]>(`/authorizations${qs(filter)}`)),
  get: async (id: number): Promise<Authorization> =>
    unwrap(await http.get<Authorization>(`/authorizations/${id}`)),
  create: async (payload: CreateAuthorizationRequest): Promise<Authorization> =>
    unwrap(await http.post<Authorization>('/authorizations', payload)),
  update: async (id: number, payload: UpdateAuthorizationRequest): Promise<Authorization> =>
    unwrap(await http.patch<Authorization>(`/authorizations/${id}`, payload)),
  remove: async (id: number): Promise<number> => {
    const body = await unwrap(await http.delete<{ deleted_id: number }>(`/authorizations/${id}`));
    return body.deleted_id;
  },
};
