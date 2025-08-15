import { api } from './base';
import {
  HostDiffStatus,
  DiffDeployment,
  DeploymentResult,
  BatchDeploymentStatus,
  DeploymentHistoryEntry,
} from '../../types';

// Get diff hosts (hosts available for diff comparison)
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const getAllHostDiffs = async (): Promise<any[]> => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const response = await api.get<{ success: boolean; data: { hosts: any[] } }>('/diff');
  return response.data?.data?.hosts || [];
};

// Get diff status for a specific host
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const getHostDiff = async (hostName: string, forceUpdate?: boolean, showEmpty?: boolean): Promise<any> => {
  const params = new URLSearchParams();
  if (forceUpdate) params.append('force_update', 'true');
  if (showEmpty) params.append('show_empty', 'true');
  
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const response = await api.get<{ success: boolean; data?: any; message?: string }>(`/diff/${encodeURIComponent(hostName)}?${params}`);
  if (!response.data?.success) {
    throw new Error(response.data?.message || 'Failed to get host diff');
  }
  return response.data?.data;
};

// Get detailed diff information for a host
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const getDiffDetails = async (hostName: string): Promise<any> => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const response = await api.get<{ success: boolean; data?: any; message?: string }>(`/diff/${encodeURIComponent(hostName)}/details`);
  if (!response.data?.success) {
    throw new Error(response.data?.message || 'Failed to get host diff details');
  }
  return response.data?.data;
};

// These methods don't exist in the backend - calling code will need to be updated
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const refreshHostDiff = async (hostName: string, forceUpdate?: boolean): Promise<any> => {
  // Use the existing diff endpoint with force_update parameter
  return getHostDiff(hostName, forceUpdate);
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const refreshHostDiffs = async (hostNames: string[]): Promise<any[]> => {
  // Refresh multiple hosts by calling individual diff endpoints
  const promises = hostNames.map(name => getHostDiff(name, true));
  return Promise.all(promises);
};

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const refreshAllHostDiffs = async (): Promise<any[]> => {
  try {
    console.log('RefreshAllHostDiffs: Starting...');
    
    // First get all hosts
    const hostsResponse = await getAllHostDiffs();
    const hosts = hostsResponse || [];
    
    console.log(`RefreshAllHostDiffs: Got ${hosts.length} hosts`);
    
    if (hosts.length === 0) {
      console.warn('RefreshAllHostDiffs: No hosts found');
      return [];
    }
    
    // Process hosts in small batches to avoid overwhelming the backend
    const BATCH_SIZE = 5;
    const results: any[] = [];
    
    for (let i = 0; i < hosts.length; i += BATCH_SIZE) {
      const batch = hosts.slice(i, i + BATCH_SIZE);
      console.log(`RefreshAllHostDiffs: Processing batch ${Math.floor(i/BATCH_SIZE) + 1}/${Math.ceil(hosts.length/BATCH_SIZE)} (${batch.length} hosts)`);
      
      const batchPromises = batch.map(async (host: any) => {
        try {
          const diff = await getHostDiff(host.name, true); // force_update = true
          
          // Map backend response to frontend format
          const status = diff.is_empty ? 'synchronized' : 'out_of_sync';
          return {
            host_id: host.id,
            host: {
              ...host,
              username: 'root', // Default username, should come from host config
              port: 22 // Default port, should come from host config
            },
            status: status,
            difference_count: diff.total_items || 0,
            last_checked: new Date().toISOString(),
            error_message: null,
            key_differences: [],
            file_diff: null
          };
        } catch (error) {
          console.error(`RefreshAllHostDiffs: Failed to process host ${host.name}:`, error);
          return {
            host_id: host.id,
            host: {
              ...host,
              username: 'root',
              port: 22
            },
            status: 'error' as const,
            difference_count: 0,
            last_checked: new Date().toISOString(),
            error_message: error instanceof Error ? error.message : 'Failed to fetch host diff',
            key_differences: [],
            file_diff: null
          };
        }
      });
      
      const batchResults = await Promise.all(batchPromises);
      results.push(...batchResults);
      
      console.log(`RefreshAllHostDiffs: Completed batch ${Math.floor(i/BATCH_SIZE) + 1}, total processed: ${results.length}`);
      
      // Small delay between batches to be kind to the backend
      if (i + BATCH_SIZE < hosts.length) {
        await new Promise(resolve => setTimeout(resolve, 100));
      }
    }
    
    console.log(`RefreshAllHostDiffs: Completed processing ${results.length} hosts total`);
    return results;
  } catch (error) {
    console.error('RefreshAllHostDiffs: Fatal error:', error);
    throw error;
  }
};

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export const deployToHost = async (__deployment: DiffDeployment): Promise<DeploymentResult> => {
  throw new Error('deployToHost endpoint not available in backend');
};

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export const batchDeploy = async (__deployments: DiffDeployment[]): Promise<BatchDeploymentStatus> => {
  throw new Error('batchDeploy endpoint not available in backend');
};

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export const getBatchDeploymentStatus = async (__batchId: string): Promise<BatchDeploymentStatus> => {
  throw new Error('getBatchDeploymentStatus endpoint not available in backend');
};

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export const cancelBatchDeployment = async (_batchId: string): Promise<void> => {
  throw new Error('cancelBatchDeployment endpoint not available in backend');
};

export const getDeploymentHistory = async (
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  _hostId?: number,
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  _limit?: number,
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  _offset?: number
): Promise<DeploymentHistoryEntry[]> => {
  throw new Error('getDeploymentHistory endpoint not available in backend');
};

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export const getDeploymentHistoryEntry = async (_entryId: number): Promise<DeploymentHistoryEntry> => {
  throw new Error('getDeploymentHistoryEntry endpoint not available in backend');
};

export const rollbackDeployment = async (
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  __hostId: number,
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  _historyEntryId: number
): Promise<DeploymentResult> => {
  throw new Error('rollbackDeployment endpoint not available in backend');
};

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export const downloadBackup = async (_hostId: number, _backupFile: string): Promise<Blob> => {
  throw new Error('downloadBackup endpoint not available in backend');
};

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export const testHostConnection = async (_hostId: number): Promise<{
  success: boolean;
  message: string;
  connection_time?: number;
}> => {
  throw new Error('testHostConnection endpoint not available in backend');
};

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export const getHostConnectionStatuses = async (_hostIds: number[]): Promise<{
  [_hostId: number]: {
    success: boolean;
    message: string;
    last_checked?: string;
  };
}> => {
  throw new Error('getHostConnectionStatuses endpoint not available in backend');
};

export const exportDiffReport = async (
  _hostIds: number[],
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  _format: 'json' | 'csv' | 'html' = 'json'
): Promise<Blob> => {
  throw new Error('exportDiffReport endpoint not available in backend');
};

export const pollDiffUpdates = async (
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  __hostIds: number[],
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  _lastUpdate?: string
): Promise<{
  updates: HostDiffStatus[];
  timestamp: string;
  has_more: boolean;
}> => {
  throw new Error('pollDiffUpdates endpoint not available in backend');
};

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export const validateDeployment = async (_deployment: DiffDeployment): Promise<{
  valid: boolean;
  warnings: string[];
  errors: string[];
  estimated_time?: number;
}> => {
  throw new Error('validateDeployment endpoint not available in backend');
};

// eslint-disable-next-line @typescript-eslint/no-unused-vars
export const validateBatchDeployment = async (_deployments: DiffDeployment[]): Promise<{
  overall_valid: boolean;
  results: {
    host_id: number;
    valid: boolean;
    warnings: string[];
    errors: string[];
  }[];
  estimated_total_time?: number;
}> => {
  throw new Error('validateBatchDeployment endpoint not available in backend');
};

export const diffApi = {
  getAllHostDiffs,
  getHostDiff,
  getDiffDetails,
  refreshHostDiff,
  refreshHostDiffs,
  refreshAllHostDiffs,
  deployToHost,
  batchDeploy,
  getBatchDeploymentStatus,
  cancelBatchDeployment,
  getDeploymentHistory,
  getDeploymentHistoryEntry,
  rollbackDeployment,
  downloadBackup,
  testHostConnection,
  getHostConnectionStatuses,
  exportDiffReport,
  pollDiffUpdates,
  validateDeployment,
  validateBatchDeployment,
};

export default diffApi;