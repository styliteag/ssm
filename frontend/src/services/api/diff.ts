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
  const response = await api.get<{ hosts: any[] }>('/diff');
  return response.data?.hosts || [];
};

// Get diff status for a specific host
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const getHostDiff = async (hostName: string, forceUpdate?: boolean, showEmpty?: boolean): Promise<any> => {
  const params = new URLSearchParams();
  if (forceUpdate) params.append('force_update', 'true');
  if (showEmpty) params.append('show_empty', 'true');
  
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const response = await api.get<any>(`/diff/${encodeURIComponent(hostName)}?${params}`);
  if (!response.data) {
    throw new Error('Host diff not found');
  }
  return response.data;
};

// Get detailed diff information for a host
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const getDiffDetails = async (hostName: string): Promise<any> => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const response = await api.get<any>(`/diff/${encodeURIComponent(hostName)}/details`);
  if (!response.data) {
    throw new Error('Host diff details not found');
  }
  return response.data;
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
  throw new Error('refreshAllHostDiffs endpoint not available in backend');
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