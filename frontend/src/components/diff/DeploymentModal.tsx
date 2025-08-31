import React, { useState, useEffect } from 'react';
import {
  X,
  Play,
  AlertTriangle,
  CheckCircle,
  XCircle,
  Shield,
  FileText,
  Loader,
  Download,
} from 'lucide-react';
import { cn } from '../../utils/cn';
import {
  HostDiffStatus,
  DeploymentResult,
  BatchDeploymentStatus,
  DiffDeployment,
} from '../../types';
import { Modal, Button, Card } from '../ui';

export interface DeploymentModalProps {
  isOpen: boolean;
  onClose: () => void;
  hostDiffs: HostDiffStatus[];
  selectedDifferences: Map<number, Set<number>>; // host_id -> set of difference indices
  onDeploy: (deployments: DiffDeployment[]) => Promise<BatchDeploymentStatus>;
  className?: string;
}

const DeploymentModal: React.FC<DeploymentModalProps> = ({
  isOpen,
  onClose,
  hostDiffs,
  selectedDifferences,
  onDeploy,
  className,
}) => {
  const [deploymentState, setDeploymentState] = useState<'preview' | 'deploying' | 'completed'>('preview');
  const [createBackup, setCreateBackup] = useState(true);
  const [dryRun, setDryRun] = useState(false);
  const [batchStatus, setBatchStatus] = useState<BatchDeploymentStatus | null>(null);
  const [deploymentResults, setDeploymentResults] = useState<DeploymentResult[]>([]);

  // Reset state when modal opens/closes
  useEffect(() => {
    if (isOpen) {
      setDeploymentState('preview');
      setBatchStatus(null);
      setDeploymentResults([]);
    }
  }, [isOpen]);

  // Calculate deployment summary
  const deploymentSummary = React.useMemo(() => {
    let totalHosts = 0;
    let totalKeys = 0;
    let addKeys = 0;
    let removeKeys = 0;
    let modifyKeys = 0;

    selectedDifferences.forEach((diffIndices, hostId) => {
      if (diffIndices.size > 0) {
        totalHosts++;
        const hostDiff = hostDiffs.find(h => h.host_id === hostId);
        if (hostDiff?.key_differences) {
          diffIndices.forEach(index => {
            const diff = hostDiff.key_differences![index];
            if (diff) {
              totalKeys++;
              switch (diff.action) {
                case 'add':
                  addKeys++;
                  break;
                case 'remove':
                  removeKeys++;
                  break;
                case 'modify':
                  modifyKeys++;
                  break;
              }
            }
          });
        }
      }
    });

    return { totalHosts, totalKeys, addKeys, removeKeys, modifyKeys };
  }, [selectedDifferences, hostDiffs]);

  const handleStartDeployment = async () => {
    setDeploymentState('deploying');
    
    // Prepare deployment requests
    const deployments: DiffDeployment[] = [];
    
    selectedDifferences.forEach((diffIndices, hostId) => {
      if (diffIndices.size > 0) {
        const hostDiff = hostDiffs.find(h => h.host_id === hostId);
        if (hostDiff?.key_differences) {
          const selectedDiffs = Array.from(diffIndices)
            .map(index => hostDiff.key_differences![index])
            .filter(Boolean);
          
          deployments.push({
            host_id: hostId,
            selected_differences: selectedDiffs,
            create_backup: createBackup,
            dry_run: dryRun,
          });
        }
      }
    });

    try {
      const batchResult = await onDeploy(deployments);
      setBatchStatus(batchResult);
      setDeploymentResults(batchResult.results);
      setDeploymentState('completed');
    } catch (error) {
      console.error('Deployment failed:', error);
      setDeploymentState('preview');
    }
  };

  const handleClose = () => {
    if (deploymentState === 'deploying') {
      // Prevent closing during deployment
      return;
    }
    onClose();
  };

  const getResultIcon = (result: DeploymentResult) => {
    if (result.success) {
      return <CheckCircle size={20} className="text-green-600 dark:text-green-400" />;
    } else {
      return <XCircle size={20} className="text-red-600 dark:text-red-400" />;
    }
  };

  const downloadDeploymentReport = () => {
    if (!batchStatus) return;

    const report = [
      `SSH Key Deployment Report`,
      `Generated: ${new Date().toISOString()}`,
      ``,
      `Summary:`,
      `- Total Hosts: ${batchStatus.total_hosts}`,
      `- Successful: ${batchStatus.successful_deploys}`,
      `- Failed: ${batchStatus.failed_deploys}`,
      `- Total Keys: ${deploymentSummary.totalKeys}`,
      ``,
      `Results:`,
      ...batchStatus.results.map(result => {
        const host = hostDiffs.find(h => h.host_id === result.host_id)?.host;
        return [
          ``,
          `Host: ${host?.name || `ID ${result.host_id}`}`,
          `Status: ${result.success ? 'SUCCESS' : 'FAILED'}`,
          `Message: ${result.message}`,
          `Keys Deployed: ${result.deployed_keys || 0}`,
          ...(result.backup_file ? [`Backup: ${result.backup_file}`] : []),
          ...(result.errors ? result.errors.map(err => `Error: ${err}`) : []),
        ].join('\n');
      }),
    ].join('\n');

    const blob = new Blob([report], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `ssh-deployment-report-${new Date().toISOString().split('T')[0]}.txt`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  const PreviewContent = () => (
    <div className="space-y-6">
      <div className="text-center">
        <h3 className="text-lg font-medium text-gray-900 dark:text-gray-100 mb-2">
          Deploy SSH Key Changes
        </h3>
        <p className="text-gray-600 dark:text-gray-400">
          Review and confirm the changes to be deployed to selected hosts
        </p>
      </div>

      {/* Deployment Summary */}
      <Card className="p-6 bg-blue-50 dark:bg-blue-900/20 border-blue-200 dark:border-blue-800">
        <h4 className="font-medium text-blue-900 dark:text-blue-100 mb-4">Deployment Summary</h4>
        <div className="grid grid-cols-2 md:grid-cols-5 gap-4 text-center">
          <div>
            <div className="text-2xl font-bold text-blue-600 dark:text-blue-400">
              {deploymentSummary.totalHosts}
            </div>
            <div className="text-sm text-blue-700 dark:text-blue-300">Hosts</div>
          </div>
          <div>
            <div className="text-2xl font-bold text-green-600 dark:text-green-400">
              {deploymentSummary.addKeys}
            </div>
            <div className="text-sm text-green-700 dark:text-green-300">Add Keys</div>
          </div>
          <div>
            <div className="text-2xl font-bold text-red-600 dark:text-red-400">
              {deploymentSummary.removeKeys}
            </div>
            <div className="text-sm text-red-700 dark:text-red-300">Remove Keys</div>
          </div>
          <div>
            <div className="text-2xl font-bold text-yellow-600 dark:text-yellow-400">
              {deploymentSummary.modifyKeys}
            </div>
            <div className="text-sm text-yellow-700 dark:text-yellow-300">Modify Keys</div>
          </div>
          <div>
            <div className="text-2xl font-bold text-gray-600 dark:text-gray-400">
              {deploymentSummary.totalKeys}
            </div>
            <div className="text-sm text-gray-700 dark:text-gray-300">Total Keys</div>
          </div>
        </div>
      </Card>

      {/* Deployment Options */}
      <Card className="p-6">
        <h4 className="font-medium text-gray-900 dark:text-gray-100 mb-4">Deployment Options</h4>
        <div className="space-y-4">
          <label className="flex items-center space-x-3">
            <input
              type="checkbox"
              checked={createBackup}
              onChange={(e) => setCreateBackup(e.target.checked)}
              className="rounded border-gray-300 text-blue-600 focus:ring-blue-500"
            />
            <div className="flex items-center space-x-2">
              <Shield size={16} className="text-gray-500 dark:text-gray-400" />
              <span className="text-gray-900 dark:text-gray-100">Create backup before deployment</span>
            </div>
          </label>
          
          <label className="flex items-center space-x-3">
            <input
              type="checkbox"
              checked={dryRun}
              onChange={(e) => setDryRun(e.target.checked)}
              className="rounded border-gray-300 text-blue-600 focus:ring-blue-500"
            />
            <div className="flex items-center space-x-2">
              <FileText size={16} className="text-gray-500 dark:text-gray-400" />
              <span className="text-gray-900 dark:text-gray-100">Dry run (preview changes only)</span>
            </div>
          </label>
        </div>
      </Card>

      {/* Host Details */}
      <div className="space-y-4">
        <h4 className="font-medium text-gray-900 dark:text-gray-100">Affected Hosts</h4>
        {Array.from(selectedDifferences.entries()).map(([hostId, diffIndices]) => {
          const hostDiff = hostDiffs.find(h => h.host_id === hostId);
          if (!hostDiff || diffIndices.size === 0) return null;

          return (
            <Card key={hostId} className="p-4">
              <div className="flex items-center justify-between mb-3">
                <h5 className="font-medium text-gray-900 dark:text-gray-100">
                  {hostDiff.host.name}
                </h5>
                <span className="text-sm text-gray-600 dark:text-gray-400">
                  {diffIndices.size} changes
                </span>
              </div>
              <div className="text-sm text-gray-600 dark:text-gray-400">
                {hostDiff.host.address}:{hostDiff.host.port} ({hostDiff.host.username})
              </div>
            </Card>
          );
        })}
      </div>
    </div>
  );

  const DeployingContent = () => (
    <div className="space-y-6 text-center">
      <div className="flex flex-col items-center space-y-4">
        <Loader size={48} className="animate-spin text-blue-600 dark:text-blue-400" />
        <h3 className="text-lg font-medium text-gray-900 dark:text-gray-100">
          Deploying Changes...
        </h3>
        <p className="text-gray-600 dark:text-gray-400">
          Please wait while we deploy the SSH key changes to your hosts
        </p>
      </div>

      {batchStatus && (
        <Card className="p-6">
          <div className="space-y-4">
            <div className="flex items-center justify-between">
              <span className="text-gray-700 dark:text-gray-300">Progress</span>
              <span className="text-sm text-gray-600 dark:text-gray-400">
                {batchStatus.completed_hosts} / {batchStatus.total_hosts} hosts
              </span>
            </div>
            <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2">
              <div
                className="bg-blue-600 dark:bg-blue-400 h-2 rounded-full transition-all duration-300"
                style={{
                  width: `${(batchStatus.completed_hosts / batchStatus.total_hosts) * 100}%`,
                }}
              />
            </div>
          </div>
        </Card>
      )}
    </div>
  );

  const CompletedContent = () => (
    <div className="space-y-6">
      <div className="text-center">
        <div className="mx-auto w-16 h-16 rounded-full bg-green-100 dark:bg-green-900/20 flex items-center justify-center mb-4">
          <CheckCircle size={32} className="text-green-600 dark:text-green-400" />
        </div>
        <h3 className="text-lg font-medium text-gray-900 dark:text-gray-100 mb-2">
          Deployment Complete
        </h3>
        <p className="text-gray-600 dark:text-gray-400">
          SSH key deployment has finished
        </p>
      </div>

      {/* Results Summary */}
      {batchStatus && (
        <Card className="p-6 bg-gray-50 dark:bg-gray-800">
          <h4 className="font-medium text-gray-900 dark:text-gray-100 mb-4">Results Summary</h4>
          <div className="grid grid-cols-3 gap-4 text-center">
            <div>
              <div className="text-2xl font-bold text-gray-600 dark:text-gray-400">
                {batchStatus.total_hosts}
              </div>
              <div className="text-sm text-gray-700 dark:text-gray-300">Total Hosts</div>
            </div>
            <div>
              <div className="text-2xl font-bold text-green-600 dark:text-green-400">
                {batchStatus.successful_deploys}
              </div>
              <div className="text-sm text-green-700 dark:text-green-300">Successful</div>
            </div>
            <div>
              <div className="text-2xl font-bold text-red-600 dark:text-red-400">
                {batchStatus.failed_deploys}
              </div>
              <div className="text-sm text-red-700 dark:text-red-300">Failed</div>
            </div>
          </div>
        </Card>
      )}

      {/* Detailed Results */}
      <div className="space-y-3">
        <h4 className="font-medium text-gray-900 dark:text-gray-100">Deployment Results</h4>
        {deploymentResults.map((result) => {
          const host = hostDiffs.find(h => h.host_id === result.host_id)?.host;
          return (
            <Card key={result.host_id} className="p-4">
              <div className="flex items-start space-x-3">
                {getResultIcon(result)}
                <div className="flex-1">
                  <div className="flex items-center justify-between">
                    <h5 className="font-medium text-gray-900 dark:text-gray-100">
                      {host?.name || `Host ${result.host_id}`}
                    </h5>
                    <span className="text-sm text-gray-600 dark:text-gray-400">
                      {result.deployed_keys || 0} keys
                    </span>
                  </div>
                  <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                    {result.message}
                  </p>
                  {result.backup_file && (
                    <p className="text-xs text-gray-500 dark:text-gray-500 mt-1">
                      Backup: {result.backup_file}
                    </p>
                  )}
                  {result.errors && result.errors.length > 0 && (
                    <div className="mt-2 text-sm text-red-600 dark:text-red-400">
                      {result.errors.map((error, index) => (
                        <div key={index}>• {error}</div>
                      ))}
                    </div>
                  )}
                </div>
              </div>
            </Card>
          );
        })}
      </div>
    </div>
  );

  return (
    <Modal isOpen={isOpen} onClose={handleClose} className={cn('max-w-4xl', className)}>
      <div className="flex items-center justify-between p-6 border-b border-gray-200 dark:border-gray-700">
        <h2 className="text-xl font-semibold text-gray-900 dark:text-gray-100">
          {deploymentState === 'preview' && 'Deploy SSH Key Changes'}
          {deploymentState === 'deploying' && 'Deploying Changes...'}
          {deploymentState === 'completed' && 'Deployment Complete'}
        </h2>
        <Button
          variant="ghost"
          size="sm"
          onClick={handleClose}
          disabled={deploymentState === 'deploying'}
          leftIcon={<X size={16} />}
        />
      </div>

      <div className="p-6 max-h-[70vh] overflow-y-auto">
        {deploymentState === 'preview' && <PreviewContent />}
        {deploymentState === 'deploying' && <DeployingContent />}
        {deploymentState === 'completed' && <CompletedContent />}
      </div>

      <div className="flex items-center justify-between p-6 border-t border-gray-200 dark:border-gray-700">
        <div className="flex items-center space-x-2">
          {deploymentState === 'preview' && dryRun && (
            <div className="flex items-center space-x-2 text-yellow-600 dark:text-yellow-400">
              <AlertTriangle size={16} />
              <span className="text-sm">This is a dry run - no changes will be made</span>
            </div>
          )}
        </div>

        <div className="flex items-center space-x-3">
          {deploymentState === 'preview' && (
            <>
              <Button variant="ghost" onClick={handleClose}>
                Cancel
              </Button>
              <Button
                onClick={handleStartDeployment}
                disabled={deploymentSummary.totalKeys === 0}
                leftIcon={<Play size={16} />}
              >
                {dryRun ? 'Preview Changes' : 'Deploy Changes'}
              </Button>
            </>
          )}

          {deploymentState === 'completed' && (
            <>
              <Button
                variant="ghost"
                onClick={downloadDeploymentReport}
                leftIcon={<Download size={16} />}
              >
                Download Report
              </Button>
              <Button onClick={handleClose}>
                Close
              </Button>
            </>
          )}
        </div>
      </div>
    </Modal>
  );
};

export default DeploymentModal;