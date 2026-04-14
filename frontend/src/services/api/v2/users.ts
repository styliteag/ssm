import { http, unwrap } from './base';
import { User } from './types';

export interface CreateUserRequest {
  username: string;
  enabled?: boolean;
  comment?: string | null;
}

export type UpdateUserRequest = Partial<CreateUserRequest>;

export const usersApi = {
  list: async (): Promise<User[]> => unwrap(await http.get<User[]>('/users')),
  get: async (id: number): Promise<User> => unwrap(await http.get<User>(`/users/${id}`)),
  create: async (payload: CreateUserRequest): Promise<User> =>
    unwrap(await http.post<User>('/users', payload)),
  update: async (id: number, payload: UpdateUserRequest): Promise<User> =>
    unwrap(await http.patch<User>(`/users/${id}`, payload)),
  remove: async (id: number): Promise<number> => {
    const body = await unwrap(await http.delete<{ deleted_id: number }>(`/users/${id}`));
    return body.deleted_id;
  },
};
