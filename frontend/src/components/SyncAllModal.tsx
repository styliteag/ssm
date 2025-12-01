import React, { useState } from 'react';
import { Upload, CheckCircle, XCircle, AlertCircle, ChevronDown, ChevronUp, Loader2 } from 'lucide-react';
import { Modal, Button } from './ui';
import { DetailedDiffResponse } from '../services/api/diff';
import DiffIssue from './DiffIssue';

export interface HostSyncInfo {
  id: number;
  name: string;
  address: string;
  totalIssues: number;
  disabled: boolean;
  error?: string;
}

export interface SyncProgress {
  hostName: string;
  status: 'pending' | 'syncing' | 'success' | 'error';
  error?: string;
}

interface SyncAllModalProps {
  isOpen: boolean;
  onClose: () => void;
  hosts: HostSyncInfo[];
  onSync: (onProgress: (progress: SyncProgress) => void) => Promise<void>;
  onFetchDetails?: (hostName: string) => Promise<DetailedDiffResponse | null>;
}

const SyncAllModal: React.FC<SyncAllModalProps> = ({
  isOpen,
  onClose,
  hosts,
  onSync,
  onFetchDetails
}) => {
  const [syncing, setSyncing] = useState(false);
  const [syncComplete, setSyncComplete] = useState(false);
  const [progress, setProgress] = useState<Record<string, SyncProgress>>({});
  const [currentIndex, setCurrentIndex] = useState(0);
  const [expandedHost, setExpandedHost] = useState<string | null>(null);
  const [hostDetails, setHostDetails] = useState<Record<string, DetailedDiffResponse>>({});
  const [loadingDetails, setLoadingDetails] = useState<string | null>(null);
  const [errorHost, setErrorHost] = useState<{ name: string; error: string } | null>(null);

  // Filter out disabled hosts
  const syncableHosts = hosts.filter(h => !h.disabled);
  const totalIssues = syncableHosts.reduce((sum, h) => sum + h.totalIssues, 0);

  const handleSync = async () => {
    setSyncing(true);
    setErrorHost(null);

    // Initialize progress for all hosts
    const initialProgress: Record<string, SyncProgress> = {};
    syncableHosts.forEach(host => {
      initialProgress[host.name] = { hostName: host.name, status: 'pending' };
    });
    setProgress(initialProgress);
    setCurrentIndex(0);

    try {
      await onSync((progressUpdate: SyncProgress) => {
        setProgress(prev => ({
          ...prev,
          [progressUpdate.hostName]: progressUpdate
        }));

        if (progressUpdate.status === 'syncing') {
          const index = syncableHosts.findIndex(h => h.name === progressUpdate.hostName);
          setCurrentIndex(index);
        }

        if (progressUpdate.status === 'error') {
          setErrorHost({ name: progressUpdate.hostName, error: progressUpdate.error || 'Unknown error' });
          setSyncing(false);
        }

        if (progressUpdate.status === 'success') {
          const index = syncableHosts.findIndex(h => h.name === progressUpdate.hostName);
          if (index === syncableHosts.length - 1) {
            // Last host completed
            setSyncComplete(true);
            setSyncing(false);
          }
        }
      });
    } catch (error) {
      console.error('Sync failed:', error);
      setSyncing(false);
    }
  };

  const handleContinue = () => {
    setErrorHost(null);
    setSyncing(true);
  };

  const handleStop = () => {
    setErrorHost(null);
    setSyncComplete(true);
  };

  const handleClose = () => {
    setSyncComplete(false);
    setSyncing(false);
    setProgress({});
    setCurrentIndex(0);
    setExpandedHost(null);
    setHostDetails({});
    setErrorHost(null);
    onClose();
  };

  const handleToggleDetails = async (hostName: string) => {
    if (expandedHost === hostName) {
      setExpandedHost(null);
      return;
    }

    setExpandedHost(hostName);

    // Fetch details if not already loaded
    if (!hostDetails[hostName] && onFetchDetails) {
      setLoadingDetails(hostName);
      try {
        const details = await onFetchDetails(hostName);
        if (details) {
          setHostDetails(prev => ({ ...prev, [hostName]: details }));
        }
      } catch (error) {
        console.error(`Failed to fetch details for ${hostName}:`, error);
      } finally {
        setLoadingDetails(null);
      }
    }
  };

  const getStatusIcon = (status: SyncProgress['status']) => {
    switch (status) {
      case 'pending':
        return <div className="w-5 h-5 rounded-full bg-gray-300 dark:bg-gray-600" />;
      case 'syncing':
        return <Loader2 className="w-5 h-5 text-blue-500 animate-spin" />;
      case 'success':
        return <CheckCircle className="w-5 h-5 text-green-500" />;
      case 'error':
        return <XCircle className="w-5 h-5 text-red-500" />;
    }
  };

  const successCount = Object.values(progress).filter(p => p.status === 'success').length;
  const errorCount = Object.values(progress).filter(p => p.status === 'error').length;

  return (
    <Modal
      isOpen={isOpen}
      onClose={handleClose}
      title="Sync All Hosts"
      size="lg"
    >
      <div className="space-y-6">
        {/* Complete Status */}
        {syncComplete && (
          <div className="bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg p-4">
            <div className="flex items-center space-x-3">
              <CheckCircle className="w-6 h-6 text-green-600 dark:text-green-400" />
              <div className="flex-1">
                <h3 className="text-green-800 dark:text-green-200 font-medium">
                  Sync Completed
                </h3>
                <p className="text-green-700 dark:text-green-300 text-sm mt-1">
                  Successfully synced {successCount} of {syncableHosts.length} hosts
                  {errorCount > 0 && ` (${errorCount} failed)`}
                </p>
              </div>
            </div>
          </div>
        )}

        {/* Error Handler */}
        {errorHost && !syncComplete && (
          <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4">
            <div className="flex items-start space-x-3">
              <AlertCircle className="w-5 h-5 text-red-600 dark:text-red-400 mt-0.5" />
              <div className="flex-1">
                <h3 className="text-red-800 dark:text-red-200 font-medium">Sync Error</h3>
                <p className="text-red-700 dark:text-red-300 text-sm mt-1">
                  Failed to sync <strong>{errorHost.name}</strong>: {errorHost.error}
                </p>
                <div className="flex space-x-3 mt-3">
                  <Button
                    onClick={handleStop}
                    variant="secondary"
                    size="sm"
                  >
                    Stop Here
                  </Button>
                  <Button
                    onClick={handleContinue}
                    variant="primary"
                    size="sm"
                    className="bg-blue-600 hover:bg-blue-700"
                  >
                    Continue with Remaining
                  </Button>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Preview Mode - Before Sync */}
        {!syncing && !syncComplete && !errorHost && (
          <>
            <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-4">
              <div className="flex items-start space-x-3">
                <Upload className="w-5 h-5 text-blue-600 dark:text-blue-400 mt-0.5" />
                <div>
                  <h3 className="text-blue-800 dark:text-blue-200 font-medium">
                    Synchronization Preview
                  </h3>
                  <p className="text-blue-700 dark:text-blue-300 text-sm mt-1">
                    {syncableHosts.length} host{syncableHosts.length !== 1 ? 's' : ''} will be synchronized with a total of {totalIssues} change{totalIssues !== 1 ? 's' : ''}
                  </p>
                </div>
              </div>
            </div>

            <div className="bg-white dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700 p-4">
              <h4 className="text-lg font-semibold text-gray-900 dark:text-gray-100 mb-4">
                Hosts to Sync
              </h4>
              <div className="space-y-2 max-h-96 overflow-y-auto">
                {syncableHosts.map((host) => (
                  <div
                    key={host.id}
                    className="border border-gray-200 dark:border-gray-700 rounded-lg overflow-hidden"
                  >
                    <div
                      className="flex items-center justify-between p-3 bg-gray-50 dark:bg-gray-800 hover:bg-gray-100 dark:hover:bg-gray-750 cursor-pointer"
                      onClick={() => handleToggleDetails(host.name)}
                    >
                      <div className="flex items-center space-x-3 flex-1">
                        <CheckCircle className="w-5 h-5 text-green-500" />
                        <div className="flex-1">
                          <div className="font-medium text-gray-900 dark:text-gray-100">
                            {host.name}
                          </div>
                          <div className="text-xs text-gray-600 dark:text-gray-400">
                            {host.address} • {host.totalIssues} change{host.totalIssues !== 1 ? 's' : ''}
                          </div>
                        </div>
                      </div>
                      <button className="text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200">
                        {expandedHost === host.name ? (
                          <ChevronUp className="w-5 h-5" />
                        ) : (
                          <ChevronDown className="w-5 h-5" />
                        )}
                      </button>
                    </div>

                    {/* Expanded Details */}
                    {expandedHost === host.name && (
                      <div className="p-4 border-t border-gray-200 dark:border-gray-700">
                        {loadingDetails === host.name ? (
                          <div className="flex items-center justify-center py-4">
                            <Loader2 className="w-5 h-5 animate-spin text-blue-500 mr-2" />
                            <span className="text-sm text-gray-600 dark:text-gray-400">
                              Loading details...
                            </span>
                          </div>
                        ) : hostDetails[host.name] ? (
                          <div className="space-y-3">
                            {hostDetails[host.name].logins.map((loginDiff, idx) => (
                              <div key={idx} className="space-y-2">
                                <div className="text-sm font-medium text-gray-700 dark:text-gray-300">
                                  Login: <code className="bg-gray-200 dark:bg-gray-700 px-2 py-0.5 rounded">{loginDiff.login}</code>
                                </div>
                                {loginDiff.issues.map((issue, issueIdx) => (
                                  <DiffIssue key={issueIdx} issue={issue} />
                                ))}
                              </div>
                            ))}
                          </div>
                        ) : (
                          <div className="text-sm text-gray-600 dark:text-gray-400">
                            Failed to load details
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                ))}
              </div>
            </div>
          </>
        )}

        {/* Progress Mode - During Sync */}
        {(syncing || syncComplete) && Object.keys(progress).length > 0 && (
          <div className="bg-white dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700 p-4">
            <div className="flex items-center justify-between mb-4">
              <h4 className="text-lg font-semibold text-gray-900 dark:text-gray-100">
                {syncComplete ? 'Sync Results' : 'Syncing Hosts'}
              </h4>
              {!syncComplete && (
                <span className="text-sm text-gray-600 dark:text-gray-400">
                  {currentIndex + 1} of {syncableHosts.length}
                </span>
              )}
            </div>

            <div className="space-y-2 max-h-96 overflow-y-auto">
              {syncableHosts.map((host) => {
                const hostProgress = progress[host.name];
                return (
                  <div
                    key={host.id}
                    className="flex items-center justify-between p-3 border border-gray-200 dark:border-gray-700 rounded-lg"
                  >
                    <div className="flex items-center space-x-3 flex-1">
                      {getStatusIcon(hostProgress.status)}
                      <div className="flex-1">
                        <div className="font-medium text-gray-900 dark:text-gray-100">
                          {host.name}
                        </div>
                        <div className="text-xs text-gray-600 dark:text-gray-400">
                          {host.address}
                        </div>
                      </div>
                      {hostProgress.status === 'error' && hostProgress.error && (
                        <div className="text-xs text-red-600 dark:text-red-400 max-w-xs truncate">
                          {hostProgress.error}
                        </div>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>

            {syncComplete && (
              <div className="mt-4 pt-4 border-t border-gray-200 dark:border-gray-700">
                <div className="text-sm text-gray-600 dark:text-gray-400">
                  <span className="text-green-600 dark:text-green-400 font-medium">{successCount} succeeded</span>
                  {errorCount > 0 && (
                    <>
                      {' • '}
                      <span className="text-red-600 dark:text-red-400 font-medium">{errorCount} failed</span>
                    </>
                  )}
                </div>
              </div>
            )}
          </div>
        )}

        {/* Action Buttons */}
        <div className="flex justify-end space-x-3 pt-4 border-t border-gray-200 dark:border-gray-700">
          {!syncing && !syncComplete && !errorHost && (
            <>
              <Button
                onClick={handleClose}
                variant="secondary"
              >
                Cancel
              </Button>
              <Button
                onClick={handleSync}
                leftIcon={<Upload size={16} />}
                variant="primary"
                className="bg-blue-600 hover:bg-blue-700"
                disabled={syncableHosts.length === 0}
              >
                Sync All ({syncableHosts.length} {syncableHosts.length === 1 ? 'host' : 'hosts'})
              </Button>
            </>
          )}

          {syncComplete && (
            <Button
              onClick={handleClose}
              variant="primary"
              className="bg-blue-600 hover:bg-blue-700"
            >
              Close
            </Button>
          )}
        </div>
      </div>
    </Modal>
  );
};

export default SyncAllModal;
