import { http, unwrap } from './base';
import { Host } from './types';

export interface CreateHostRequest {
  name: string;
  username: string;
  address: string;
  port?: number;
  key_fingerprint?: string | null;
  jump_via?: number | null;
  disabled?: boolean;
  comment?: string | null;
}

export type UpdateHostRequest = Partial<CreateHostRequest>;

export const hostsApi = {
  list: async (): Promise<Host[]> => unwrap(await http.get<Host[]>('/hosts')),
  get: async (id: number): Promise<Host> => unwrap(await http.get<Host>(`/hosts/${id}`)),
  create: async (payload: CreateHostRequest): Promise<Host> =>
    unwrap(await http.post<Host>('/hosts', payload)),
  update: async (id: number, payload: UpdateHostRequest): Promise<Host> =>
    unwrap(await http.patch<Host>(`/hosts/${id}`, payload)),
  remove: async (id: number): Promise<number> => {
    const body = await unwrap(await http.delete<{ deleted_id: number }>(`/hosts/${id}`));
    return body.deleted_id;
  },
};
