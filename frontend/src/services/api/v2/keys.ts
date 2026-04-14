import { http, unwrap } from './base';
import { UserKey } from './types';

export interface CreateKeyRequest {
  user_id: number;
  key_type: string;
  key_base64: string;
  name?: string | null;
  extra_comment?: string | null;
}

export interface UpdateKeyRequest {
  name?: string | null;
  extra_comment?: string | null;
}

export const keysApi = {
  list: async (userId?: number): Promise<UserKey[]> => {
    const url = userId !== undefined ? `/keys?user_id=${userId}` : '/keys';
    return unwrap(await http.get<UserKey[]>(url));
  },
  get: async (id: number): Promise<UserKey> => unwrap(await http.get<UserKey>(`/keys/${id}`)),
  create: async (payload: CreateKeyRequest): Promise<UserKey> =>
    unwrap(await http.post<UserKey>('/keys', payload)),
  update: async (id: number, payload: UpdateKeyRequest): Promise<UserKey> =>
    unwrap(await http.patch<UserKey>(`/keys/${id}`, payload)),
  remove: async (id: number): Promise<number> => {
    const body = await unwrap(await http.delete<{ deleted_id: number }>(`/keys/${id}`));
    return body.deleted_id;
  },
};
