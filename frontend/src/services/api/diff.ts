import { api } from './base';
import {
  HostDiffStatus,
  DiffDeployment,
  DeploymentResult,
  BatchDeploymentStatus,
  DeploymentHistoryEntry,
} from '../../types';

// Get diff status for all hosts
export const getAllHostDiffs = async (): Promise<HostDiffStatus[]> => {
  const response = await api.get<HostDiffStatus[]>('/diff/hosts');
  return response.data || [];
};

// Get diff status for a specific host
export const getHostDiff = async (hostId: number): Promise<HostDiffStatus> => {
  const response = await api.get<HostDiffStatus>(`/diff/hosts/${hostId}`);
  if (!response.data) {
    throw new Error('Host diff not found');
  }
  return response.data;
};

// Refresh diff status for a specific host (trigger new SSH check)
export const refreshHostDiff = async (hostId: number): Promise<HostDiffStatus> => {
  const response = await api.post<HostDiffStatus>(`/diff/hosts/${hostId}/refresh`);
  if (!response.data) {
    throw new Error('Failed to refresh host diff');
  }
  return response.data;
};

// Refresh diff status for multiple hosts
export const refreshHostDiffs = async (hostIds: number[]): Promise<HostDiffStatus[]> => {
  const response = await api.post<HostDiffStatus[]>('/diff/hosts/refresh', { host_ids: hostIds });
  return response.data || [];
};

// Refresh diff status for all hosts
export const refreshAllHostDiffs = async (): Promise<HostDiffStatus[]> => {
  const response = await api.post<HostDiffStatus[]>('/diff/hosts/refresh-all');
  return response.data || [];
};

// Deploy changes to a single host
export const deployToHost = async (deployment: DiffDeployment): Promise<DeploymentResult> => {
  const response = await api.post<DeploymentResult>('/diff/deploy', deployment);
  if (!response.data) {
    throw new Error('Deployment failed');
  }
  return response.data;
};

// Deploy changes to multiple hosts (batch deployment)
export const batchDeploy = async (deployments: DiffDeployment[]): Promise<BatchDeploymentStatus> => {
  const response = await api.post<BatchDeploymentStatus>('/diff/deploy/batch', { deployments });
  if (!response.data) {
    throw new Error('Batch deployment failed');
  }
  return response.data;
};

// Get deployment status for a batch deployment
export const getBatchDeploymentStatus = async (batchId: string): Promise<BatchDeploymentStatus> => {
  const response = await api.get<BatchDeploymentStatus>(`/diff/deploy/batch/${batchId}/status`);
  if (!response.data) {
    throw new Error('Batch deployment status not found');
  }
  return response.data;
};

// Cancel a running batch deployment
export const cancelBatchDeployment = async (batchId: string): Promise<void> => {
  await api.post(`/diff/deploy/batch/${batchId}/cancel`);
};

// Get deployment history
export const getDeploymentHistory = async (
  hostId?: number,
  limit?: number,
  offset?: number
): Promise<DeploymentHistoryEntry[]> => {
  const params = new URLSearchParams();
  if (hostId) params.append('host_id', hostId.toString());
  if (limit) params.append('limit', limit.toString());
  if (offset) params.append('offset', offset.toString());

  const response = await api.get<DeploymentHistoryEntry[]>(`/diff/history?${params}`);
  return response.data || [];
};

// Get a specific deployment history entry
export const getDeploymentHistoryEntry = async (entryId: number): Promise<DeploymentHistoryEntry> => {
  const response = await api.get<DeploymentHistoryEntry>(`/diff/history/${entryId}`);
  if (!response.data) {
    throw new Error('Deployment history entry not found');
  }
  return response.data;
};

// Rollback to a previous deployment
export const rollbackDeployment = async (
  hostId: number,
  historyEntryId: number
): Promise<DeploymentResult> => {
  const response = await api.post<DeploymentResult>(`/diff/rollback`, {
    host_id: hostId,
    history_entry_id: historyEntryId,
  });
  if (!response.data) {
    throw new Error('Rollback failed');
  }
  return response.data;
};

// Download backup file
export const downloadBackup = async (hostId: number, backupFile: string): Promise<Blob> => {
  const response = await api.get(`/diff/backup/${hostId}/${encodeURIComponent(backupFile)}`, {
    responseType: 'blob',
  });
  return response.data as unknown as Blob;
};

// Test SSH connection to a host (dry run)
export const testHostConnection = async (hostId: number): Promise<{
  success: boolean;
  message: string;
  connection_time?: number;
}> => {
  const response = await api.post<{
    success: boolean;
    message: string;
    connection_time?: number;
  }>(`/diff/test-connection/${hostId}`);
  return response.data || { success: false, message: 'Unknown error' };
};

// Get SSH connection status for multiple hosts
export const getHostConnectionStatuses = async (hostIds: number[]): Promise<{
  [hostId: number]: {
    success: boolean;
    message: string;
    last_checked?: string;
  };
}> => {
  const response = await api.post<{
    [hostId: number]: {
      success: boolean;
      message: string;
      last_checked?: string;
    };
  }>('/diff/test-connections', { host_ids: hostIds });
  return response.data || {};
};

// Export diff report
export const exportDiffReport = async (
  hostIds: number[],
  format: 'json' | 'csv' | 'html' = 'json'
): Promise<Blob> => {
  const response = await api.post(`/diff/export/${format}`, 
    { host_ids: hostIds },
    { responseType: 'blob' }
  );
  return response.data as unknown as Blob;
};

// Get real-time diff updates (WebSocket-like polling)
export const pollDiffUpdates = async (
  hostIds: number[],
  lastUpdate?: string
): Promise<{
  updates: HostDiffStatus[];
  timestamp: string;
  has_more: boolean;
}> => {
  const params = new URLSearchParams();
  hostIds.forEach(id => params.append('host_ids', id.toString()));
  if (lastUpdate) params.append('last_update', lastUpdate);

  const response = await api.get<{
    updates: HostDiffStatus[];
    timestamp: string;
    has_more: boolean;
  }>(`/diff/poll?${params}`);
  
  return response.data || { updates: [], timestamp: new Date().toISOString(), has_more: false };
};

// Validate deployment before executing
export const validateDeployment = async (deployment: DiffDeployment): Promise<{
  valid: boolean;
  warnings: string[];
  errors: string[];
  estimated_time?: number;
}> => {
  const response = await api.post<{
    valid: boolean;
    warnings: string[];
    errors: string[];
    estimated_time?: number;
  }>('/diff/validate', deployment);
  
  return response.data || { valid: false, warnings: [], errors: ['Unknown validation error'] };
};

// Validate batch deployment
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
  const response = await api.post<{
    overall_valid: boolean;
    results: {
      host_id: number;
      valid: boolean;
      warnings: string[];
      errors: string[];
    }[];
    estimated_total_time?: number;
  }>('/diff/validate/batch', { deployments });
  
  return response.data || { 
    overall_valid: false, 
    results: [],
  };
};

export const diffApi = {
  getAllHostDiffs,
  getHostDiff,
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