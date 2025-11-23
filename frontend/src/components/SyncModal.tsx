import React, { useState } from 'react';
import { Upload, AlertTriangle, CheckCircle, RefreshCw } from 'lucide-react';
import { Modal, Button } from './ui';
import { DetailedDiffResponse } from '../services/api/diff';
import DiffIssue from './DiffIssue';

interface SyncModalProps {
  isOpen: boolean;
  onClose: () => void;
  hostDetails: DetailedDiffResponse | null;
  onSync: () => Promise<void>;
}

const SyncModal: React.FC<SyncModalProps> = ({ isOpen, onClose, hostDetails, onSync }) => {
  const [syncing, setSyncing] = useState(false);
  const [syncComplete, setSyncComplete] = useState(false);

  const handleSync = async () => {
    try {
      setSyncing(true);
      await onSync();
      setSyncComplete(true);
      // Auto-close after 2 seconds
      setTimeout(() => {
        setSyncComplete(false);
        onClose();
      }, 2000);
    } catch (error) {
      console.error('Sync failed:', error);
    } finally {
      setSyncing(false);
    }
  };

  const handleClose = () => {
    setSyncComplete(false);
    onClose();
  };

  if (!hostDetails) return null;

  const totalIssues = hostDetails.logins.reduce((sum, login) => sum + login.issues.length, 0);
  const hasIssues = totalIssues > 0;

  return (
    <Modal
      isOpen={isOpen}
      onClose={handleClose}
      title={`Sync SSH Keys - ${hostDetails.host.name}`}
      size="lg"
    >
      <div className="space-y-6">
        {/* Sync Status */}
        {syncComplete ? (
          <div className="bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg p-4">
            <div className="flex items-center space-x-3">
              <CheckCircle className="w-6 h-6 text-green-600 dark:text-green-400" />
              <div>
                <h3 className="text-green-800 dark:text-green-200 font-medium">Sync Completed Successfully!</h3>
                <p className="text-green-700 dark:text-green-300 text-sm mt-1">
                  SSH keys have been synchronized to {hostDetails.host.name}
                </p>
              </div>
            </div>
          </div>
        ) : (
          <>
            {/* Warning Header */}
            <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-4">
              <div className="flex items-start space-x-3">
                <Upload className="w-5 h-5 text-blue-600 dark:text-blue-400 mt-0.5" />
                <div>
                  <h3 className="text-blue-800 dark:text-blue-200 font-medium">Synchronization Preview</h3>
                  <p className="text-blue-700 dark:text-blue-300 text-sm mt-1">
                    The following actions will be performed on <strong>{hostDetails.host.name}</strong>:
                  </p>
                </div>
              </div>
            </div>

            {/* Changes Summary */}
            <div className="bg-white dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700 p-4">
              <div className="flex items-center justify-between mb-4">
                <h4 className="text-lg font-semibold text-gray-900 dark:text-gray-100">Changes to Apply</h4>
                <span className="inline-flex items-center px-3 py-1 rounded-full text-sm font-medium bg-blue-100 dark:bg-blue-900/30 text-blue-800 dark:text-blue-300">
                  {totalIssues} {totalIssues === 1 ? 'change' : 'changes'}
                </span>
              </div>

              {!hasIssues ? (
                <div className="text-center py-8">
                  <CheckCircle className="w-12 h-12 text-green-500 mx-auto mb-3" />
                  <p className="text-gray-600 dark:text-gray-400">No changes needed - all keys are already synchronized!</p>
                </div>
              ) : (
                <div className="max-h-96 overflow-y-auto space-y-4">
                  {hostDetails.logins.map((loginDiff, loginIndex) => (
                    <div key={loginIndex} className="border border-gray-200 dark:border-gray-700 rounded-lg overflow-hidden">
                      <div className="bg-gray-50 dark:bg-gray-800 px-4 py-3 border-b border-gray-200 dark:border-gray-700">
                        <div className="flex items-center justify-between">
                          <h5 className="text-sm font-semibold text-gray-900 dark:text-gray-100 flex items-center">
                            <span className="text-gray-600 dark:text-gray-400 mr-2">Login:</span>
                            <code className="bg-blue-100 dark:bg-blue-900/50 text-blue-800 dark:text-blue-200 px-2 py-1 rounded text-xs font-bold">{loginDiff.login}</code>
                          </h5>
                          <span className="text-xs text-gray-600 dark:text-gray-400 bg-white dark:bg-gray-700 px-2 py-1 rounded font-medium">
                            {loginDiff.issues.length} action{loginDiff.issues.length !== 1 ? 's' : ''}
                          </span>
                        </div>
                        {loginDiff.readonly_condition && (
                          <div className="text-xs text-amber-700 dark:text-amber-400 mt-2 flex items-center">
                            <span className="mr-1">🔒</span>
                            <span className="font-medium">Readonly:</span>
                            <span className="ml-1">{loginDiff.readonly_condition}</span>
                          </div>
                        )}
                      </div>
                      <div className="p-4 space-y-3">
                        {loginDiff.issues.map((issue, issueIndex) => (
                          <div key={issueIndex}>
                            <DiffIssue issue={issue} />
                          </div>
                        ))}
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* Action Buttons */}
            <div className="flex justify-between items-center pt-4 border-t border-gray-200 dark:border-gray-700">
              <div className="text-sm text-gray-600 dark:text-gray-400">
                {hasIssues ? (
                  <>This will modify authorized_keys files on the remote host.</>
                ) : (
                  <>No changes will be made as the host is already synchronized.</>
                )}
              </div>
              <div className="flex space-x-3">
                <Button
                  onClick={handleClose}
                  variant="secondary"
                  disabled={syncing}
                >
                  Cancel
                </Button>
                <Button
                  onClick={handleSync}
                  loading={syncing}
                  disabled={!hasIssues}
                  leftIcon={syncing ? <RefreshCw size={16} /> : <Upload size={16} />}
                  variant="primary"
                  className="bg-blue-600 hover:bg-blue-700"
                >
                  {syncing ? 'Synchronizing...' : 'Apply Changes'}
                </Button>
              </div>
            </div>
          </>
        )}
      </div>
    </Modal>
  );
};

export default SyncModal;