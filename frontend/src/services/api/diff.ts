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
}

// Get all hosts available for diff comparison
export const getAllHosts = async (): Promise<DiffHost[]> => {
  const response = await api.get<{ success: boolean; data: { hosts: DiffHost[] } }>('/diff');
  return response.data?.hosts || [];
};

// Get diff status for a specific host
export const getHostDiff = async (hostName: string): Promise<{
  is_empty: boolean;
  total_items: number;
  host: DiffHost;
}> => {
  const response = await api.get<{ 
    success: boolean; 
    data: {
      is_empty: boolean;
      total_items: number;
      host: DiffHost;
    };
  }>(`/diff/${encodeURIComponent(hostName)}`);
  
  if (!response.success) {
    throw new Error('Failed to get host diff');
  }
  
  return response.data?.data || { is_empty: true, total_items: 0, host: { id: 0, name: '', address: '' } };
};

// Get detailed host information for diff details view
export const getHostDiffDetails = async (hostName: string): Promise<DiffHost> => {
  const response = await api.get<{ success: boolean; data: DiffHost }>(`/diff/${encodeURIComponent(hostName)}/details`);
  
  if (!response.success) {
    throw new Error('Failed to get host details');
  }
  
  return response.data || { id: 0, name: '', address: '' };
};

export const diffApi = {
  getAllHosts,
  getHostDiff,
  getHostDiffDetails,
};

export default diffApi;