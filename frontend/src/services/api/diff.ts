import { api } from './base';

// Simple host interface for the diff page
export interface DiffHost {
  id: number;
  name: string;
  address: string;
  // Optional diff data that gets loaded asynchronously
  diff_summary?: string;
  is_empty?: boolean;
  total_items?: number;
  loading?: boolean;
  error?: string;
  // Index signature for DataTable compatibility
  [key: string]: unknown;
}

// Detailed diff response structures
export interface DiffItemResponse {
  type: 'pragma_missing' | 'faulty_key' | 'unknown_key' | 'unauthorized_key' | 'duplicate_key' | 'incorrect_options' | 'key_missing';
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

// Get all hosts available for diff comparison
export const getAllHosts = async (): Promise<DiffHost[]> => {
  const response = await api.get<{ success: boolean; data: { hosts: DiffHost[] } }>('/diff');
  return response.data?.hosts || [];
};

// Get diff status for a specific host (with detailed diff information)
export const getHostDiff = async (hostName: string, forceUpdate = false): Promise<DiffResponse> => {
  const params = forceUpdate ? '?force_update=true' : '';
  const response = await api.get<{ success: boolean; data: DiffResponse }>(`/diff/${encodeURIComponent(hostName)}${params}`);
  
  if (!response.success) {
    throw new Error('Failed to get host diff');
  }
  
  return response.data || {
    host: { id: 0, name: '', address: '' },
    cache_timestamp: '',
    diff_summary: '',
    is_empty: true,
    total_items: 0,
    logins: []
  };
};

// Get detailed host information for diff details view (with expected keys)
export const getHostDiffDetails = async (hostName: string, forceUpdate = false): Promise<DetailedDiffResponse> => {
  const params = forceUpdate ? '?force_update=true' : '';
  const response = await api.get<{ success: boolean; data: DetailedDiffResponse }>(`/diff/${encodeURIComponent(hostName)}/details${params}`);
  
  if (!response.success) {
    throw new Error('Failed to get host details');
  }
  
  return response.data || {
    host: { id: 0, name: '', address: '' },
    cache_timestamp: '',
    summary: '',
    expected_keys: [],
    logins: []
  };
};

export const diffApi = {
  getAllHosts,
  getHostDiff,
  getHostDiffDetails,
};

export default diffApi;