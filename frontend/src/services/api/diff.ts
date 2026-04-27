// Diff service — mapped onto /api/v2/hosts + /api/v2/diffs + /api/v2/authorizations.

import { api } from './base';

export interface DiffHost {
  id: number;
  name: string;
  address: string;
  disabled: boolean;
  diff_summary?: string;
  is_empty?: boolean;
  total_items?: number;
  loading?: boolean;
  error?: string;
  [key: string]: unknown;
}

export interface DiffItemResponse {
  type:
    | 'pragma_missing'
    | 'faulty_key'
    | 'unknown_key'
    | 'unauthorized_key'
    | 'duplicate_key'
    | 'incorrect_options'
    | 'key_missing';
  description: string;
  details?: {
    username?: string;
    key?: SerializableAuthorizedKey;
    expected_options?: string;
    actual_options?: string;
    error?: string;
    line?: string;
  };
}

export interface SerializableAuthorizedKey {
  options: string;
  base64: string;
  comment?: string;
  key_type: string;
}

export interface LoginDiff {
  login: string;
  readonly_condition?: string;
  issues: DiffItemResponse[];
}

export interface DiffResponse {
  host: DiffHost;
  cache_timestamp: string;
  diff_summary: string;
  is_empty: boolean;
  total_items: number;
  logins: LoginDiff[];
}

export interface ExpectedKeyInfo {
  username: string;
  login: string;
  key_base64: string;
  key_type: string;
  comment?: string;
  options?: string;
}

export interface DetailedDiffResponse {
  host: DiffHost;
  cache_timestamp: string;
  summary: string;
  expected_keys: ExpectedKeyInfo[];
  logins: LoginDiff[];
}

// Raw v2 shapes (what the backend returns today).
interface V2KeyDiff {
  status: 'present' | 'missing_on_host' | 'extra_on_host';
  line: string;
}
interface V2LoginDiff {
  login: string;
  has_pragma: boolean;
  readonly_condition: string | null;
  read_error: string | null;
  items: V2KeyDiff[];
}
interface V2HostDiff {
  host_id: number;
  host_name: string;
  disabled: boolean;
  logins: V2LoginDiff[];
}

const resolveHostId = async (name: string): Promise<{ id: number; name: string; address: string; disabled: boolean }> => {
  const list = await api.get<{ id: number; name: string; address: string; disabled: boolean }[]>('/hosts');
  const match = (list.data || []).find((h) => h.name === name);
  if (!match) throw new Error(`Host '${name}' not found`);
  return match;
};

const translateIssues = (items: V2KeyDiff[]): DiffItemResponse[] =>
  items.map((item) => {
    if (item.status === 'present') {
      return { type: 'key_missing', description: `present: ${item.line}`, details: { line: item.line } };
    }
    if (item.status === 'missing_on_host') {
      return {
        type: 'key_missing',
        description: `Key missing on host: ${item.line}`,
        details: { line: item.line },
      };
    }
    return {
      type: 'unknown_key',
      description: `Unexpected key on host: ${item.line}`,
      details: { line: item.line },
    };
  });

const translateDiff = (raw: V2HostDiff, address: string): DiffResponse => {
  const logins: LoginDiff[] = raw.logins.map((l) => ({
    login: l.login,
    readonly_condition: l.readonly_condition ?? undefined,
    issues: translateIssues(l.items.filter((i) => i.status !== 'present')),
  }));
  const total = logins.reduce((n, l) => n + l.issues.length, 0);
  return {
    host: { id: raw.host_id, name: raw.host_name, address, disabled: raw.disabled },
    cache_timestamp: new Date().toISOString(),
    diff_summary:
      total === 0 ? 'In sync' : `${total} difference${total === 1 ? '' : 's'} across ${logins.length} login(s)`,
    is_empty: total === 0,
    total_items: total,
    logins,
  };
};

export const getAllHosts = async (): Promise<DiffHost[]> => {
  const response = await api.get<DiffHost[]>('/hosts');
  return response.data || [];
};

export const getHostDiff = async (hostName: string, _forceUpdate = false): Promise<DiffResponse> => {
  const host = await resolveHostId(hostName);
  const response = await api.get<V2HostDiff>(`/diffs/${host.id}`);
  if (!response.success || !response.data) throw new Error('Failed to get host diff');
  return translateDiff(response.data, host.address);
};

export const getHostDiffDetails = async (
  hostName: string,
  forceUpdate = false,
): Promise<DetailedDiffResponse> => {
  const diff = await getHostDiff(hostName, forceUpdate);
  return {
    host: diff.host,
    cache_timestamp: diff.cache_timestamp,
    summary: diff.diff_summary,
    expected_keys: [],
    logins: diff.logins,
  };
};

export const syncKeys = async (hostName: string): Promise<void> => {
  const host = await resolveHostId(hostName);
  const response = await api.post<unknown>(`/diffs/${host.id}/sync`);
  if (!response.success) throw new Error(response.message || 'Failed to sync keys');
};

export const authorizeKey = async (
  hostName: string,
  username: string,
  login: string,
  options?: string,
): Promise<void> => {
  const [hosts, users] = await Promise.all([
    api.get<{ id: number; name: string }[]>('/hosts'),
    api.get<{ id: number; username: string }[]>('/users'),
  ]);
  const host = (hosts.data || []).find((h) => h.name === hostName);
  const user = (users.data || []).find((u) => u.username === username);
  if (!host) throw new Error(`Host ${hostName} not found`);
  if (!user) throw new Error(`User ${username} not found`);
  await api.post<unknown>('/authorizations', {
    host_id: host.id,
    user_id: user.id,
    login,
    options: options || null,
  });
};

export const diffApi = {
  getAllHosts,
  getHostDiff,
  getHostDiffDetails,
  syncKeys,
  authorizeKey,
};

export default diffApi;
