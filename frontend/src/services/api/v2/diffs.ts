import { http, unwrap } from './base';
import { HostDiff, SyncResult } from './types';

export const diffsApi = {
  get: async (hostId: number): Promise<HostDiff> =>
    unwrap(await http.get<HostDiff>(`/diffs/${hostId}`)),
  sync: async (hostId: number): Promise<SyncResult> =>
    unwrap(await http.post<SyncResult>(`/diffs/${hostId}/sync`)),
};
