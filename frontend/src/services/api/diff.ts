import { api } from './base';
import {
  HostDiffStatus,
  DiffDeployment,
  DeploymentResult,
  BatchDeploymentStatus,
  DeploymentHistoryEntry,
} from '../../types';

// Get diff hosts (hosts available for diff comparison)
export const getAllHostDiffs = async (): Promise<any[]> => {
  const response = await api.get<{ hosts: any[] }>('/diff');
  return response.data.hosts || [];
};

// Get diff status for a specific host
export const getHostDiff = async (hostName: string, forceUpdate?: boolean, showEmpty?: boolean): Promise<any> => {
  const params = new URLSearchParams();
  if (forceUpdate) params.append('force_update', 'true');
  if (showEmpty) params.append('show_empty', 'true');
  
  const response = await api.get<any>(`/diff/${encodeURIComponent(hostName)}?${params}`);
  if (!response.data) {
    throw new Error('Host diff not found');
  }
  return response.data;
};

// Get detailed diff information for a host
export const getDiffDetails = async (hostName: string): Promise<any> => {
  const response = await api.get<any>(`/diff/${encodeURIComponent(hostName)}/details`);
  if (!response.data) {
    throw new Error('Host diff details not found');
  }
  return response.data;
};

// These methods don't exist in the backend - calling code will need to be updated
export const refreshHostDiff = async (hostName: string, forceUpdate?: boolean): Promise<any> => {
  // Use the existing diff endpoint with force_update parameter
  return getHostDiff(hostName, forceUpdate);
};

export const refreshHostDiffs = async (hostNames: string[]): Promise<any[]> => {
  // Refresh multiple hosts by calling individual diff endpoints
  const promises = hostNames.map(name => getHostDiff(name, true));
  return Promise.all(promises);
};

export const refreshAllHostDiffs = async (): Promise<any[]> => {
  throw new Error('refreshAllHostDiffs endpoint not available in backend');
};

export const deployToHost = async (deployment: DiffDeployment): Promise<DeploymentResult> => {
  throw new Error('deployToHost endpoint not available in backend');
};

export const batchDeploy = async (deployments: DiffDeployment[]): Promise<BatchDeploymentStatus> => {
  throw new Error('batchDeploy endpoint not available in backend');
};

export const getBatchDeploymentStatus = async (batchId: string): Promise<BatchDeploymentStatus> => {
  throw new Error('getBatchDeploymentStatus endpoint not available in backend');
};

export const cancelBatchDeployment = async (batchId: string): Promise<void> => {
  throw new Error('cancelBatchDeployment endpoint not available in backend');
};

export const getDeploymentHistory = async (
  hostId?: number,
  limit?: number,
  offset?: number
): Promise<DeploymentHistoryEntry[]> => {
  throw new Error('getDeploymentHistory endpoint not available in backend');
};

export const getDeploymentHistoryEntry = async (entryId: number): Promise<DeploymentHistoryEntry> => {
  throw new Error('getDeploymentHistoryEntry endpoint not available in backend');
};

export const rollbackDeployment = async (
  hostId: number,
  historyEntryId: number
): Promise<DeploymentResult> => {
  throw new Error('rollbackDeployment endpoint not available in backend');
};

export const downloadBackup = async (hostId: number, backupFile: string): Promise<Blob> => {
  throw new Error('downloadBackup endpoint not available in backend');
};

export const testHostConnection = async (hostId: number): Promise<{
  success: boolean;
  message: string;
  connection_time?: number;
}> => {
  throw new Error('testHostConnection endpoint not available in backend');
};

export const getHostConnectionStatuses = async (hostIds: number[]): Promise<{
  [hostId: number]: {
    success: boolean;
    message: string;
    last_checked?: string;
  };
}> => {
  throw new Error('getHostConnectionStatuses endpoint not available in backend');
};

export const exportDiffReport = async (
  hostIds: number[],
  format: 'json' | 'csv' | 'html' = 'json'
): Promise<Blob> => {
  throw new Error('exportDiffReport endpoint not available in backend');
};

export const pollDiffUpdates = async (
  hostIds: number[],
  lastUpdate?: string
): Promise<{
  updates: HostDiffStatus[];
  timestamp: string;
  has_more: boolean;
}> => {
  throw new Error('pollDiffUpdates endpoint not available in backend');
};

export const validateDeployment = async (deployment: DiffDeployment): Promise<{
  valid: boolean;
  warnings: string[];
  errors: string[];
  estimated_time?: number;
}> => {
  throw new Error('validateDeployment endpoint not available in backend');
};

export const validateBatchDeployment = async (deployments: DiffDeployment[]): Promise<{
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