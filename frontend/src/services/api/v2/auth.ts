import { http, tokenStorage, unwrap } from './base';
import { Me, TokenPair } from './types';

export const authApi = {
  async login(username: string, password: string): Promise<TokenPair> {
    const resp = await http.post<TokenPair>('/auth/login', { username, password });
    const pair = await unwrap(resp);
    tokenStorage.setPair(pair);
    return pair;
  },

  async refresh(refresh_token: string): Promise<TokenPair> {
    const resp = await http.post<TokenPair>('/auth/refresh', { refresh_token });
    const pair = await unwrap(resp);
    tokenStorage.setPair(pair);
    return pair;
  },

  async logout(): Promise<void> {
    try {
      await http.post<{ logged_out: boolean }>('/auth/logout');
    } finally {
      tokenStorage.clear();
    }
  },

  async me(): Promise<Me> {
    return unwrap(await http.get<Me>('/auth/me'));
  },
};
