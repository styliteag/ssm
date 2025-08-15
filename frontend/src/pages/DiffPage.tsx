import React, { useState, useEffect, useCallback } from 'react';
import {
  RefreshCw,
  Upload,
  CheckCircle,
  XCircle,
  AlertTriangle,
  Clock,
  Eye,
  Download,
  Pause,
  WifiOff,
  X,
} from 'lucide-react';
import { cn } from '../utils/cn';
import {
  HostDiffStatus,
  DiffPageFilters,
  DiffDeployment,
  BatchDeploymentStatus,
} from '../types';
import {
  DataTable,
  Button,
  Card,
  Loading,
  Input,
} from '../components/ui';
import { useNotifications } from '../contexts/NotificationContext';
import { diffApi } from '../services/api';
import DiffViewer from '../components/diff/DiffViewer';
import KeyDiffTable from '../components/diff/KeyDiffTable';
import DeploymentModal from '../components/diff/DeploymentModal';
import type { Column } from '../components/ui/DataTable';

const DiffPage: React.FC = () => {
  // State management
  const [hostDiffs, setHostDiffs] = useState<HostDiffStatus[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [selectedHostId, setSelectedHostId] = useState<number | null>(null);
  const [filters, setFilters] = useState<DiffPageFilters>({
    status: 'all',
    search: '',
    show_zero_diff: false,
  });
  const [selectedHosts, setSelectedHosts] = useState<Set<number>>(new Set());
  const [selectedDifferences, setSelectedDifferences] = useState<Map<number, Set<number>>>(new Map());
  const [deploymentModalOpen, setDeploymentModalOpen] = useState(false);
  const [autoRefresh, setAutoRefresh] = useState(false);
  const [refreshInterval] = useState(30000); // 30 seconds
  
  const { addNotification } = useNotifications();

  const loadHostDiffs = useCallback(async () => {
    try {
      setLoading(true);
      const diffs = await diffApi.getAllHostDiffs();
      setHostDiffs(diffs);
    } catch (error) {
      console.error('Failed to load host diffs:', error);
      addNotification({
        type: 'error',
        title: 'Failed to load diffs',
        message: error instanceof Error ? error.message : 'Unknown error occurred',
      });
    } finally {
      setLoading(false);
    }
  }, [addNotification]);

  const handleRefreshAll = useCallback(async (silent = false) => {
    try {
      if (!silent) setRefreshing(true);
      const diffs = await diffApi.refreshAllHostDiffs();
      setHostDiffs(diffs);
      if (!silent) {
        addNotification({
          type: 'success',
          title: 'Refreshed all hosts',
          message: `Updated diff status for ${diffs.length} hosts`,
        });
      }
    } catch (error) {
      console.error('Failed to refresh host diffs:', error);
      if (!silent) {
        addNotification({
          type: 'error',
          title: 'Failed to refresh',
          message: error instanceof Error ? error.message : 'Unknown error occurred',
        });
      }
    } finally {
      if (!silent) setRefreshing(false);
    }
  }, [addNotification]);

  const handleRefreshHost = async (hostId: number) => {
    try {
      const hostDiff = hostDiffs.find(diff => diff.host_id === hostId);
      if (!hostDiff) return;
      
      const updatedDiff = await diffApi.refreshHostDiff(hostDiff.host.name);
      setHostDiffs(prev => prev.map(diff => 
        diff.host_id === hostId ? updatedDiff : diff
      ));
      addNotification({
        type: 'success',
        title: 'Host refreshed',
        message: `Updated diff status for ${updatedDiff.host.name}`,
      });
    } catch (error) {
      console.error('Failed to refresh host:', error);
      addNotification({
        type: 'error',
        title: 'Failed to refresh host',
        message: error instanceof Error ? error.message : 'Unknown error occurred',
      });
    }
  };

  const handleRefreshSelected = async () => {
    if (selectedHosts.size === 0) return;
    
    try {
      setRefreshing(true);
      const hostIds = Array.from(selectedHosts);
      const hostNames = hostIds.map(id => {
        const hostDiff = hostDiffs.find(diff => diff.host_id === id);
        return hostDiff?.host.name;
      }).filter(Boolean) as string[];
      const updatedDiffs = await diffApi.refreshHostDiffs(hostNames);
      
      setHostDiffs(prev => prev.map(diff => {
        const updated = updatedDiffs.find(u => u.host_id === diff.host_id);
        return updated || diff;
      }));
      
      addNotification({
        type: 'success',
        title: 'Selected hosts refreshed',
        message: `Updated diff status for ${updatedDiffs.length} hosts`,
      });
    } catch (error) {
      console.error('Failed to refresh selected hosts:', error);
      addNotification({
        type: 'error',
        title: 'Failed to refresh hosts',
        message: error instanceof Error ? error.message : 'Unknown error occurred',
      });
    } finally {
      setRefreshing(false);
    }
  };

  const handleSelectDifference = (hostId: number, differenceIndex: number, selected: boolean) => {
    setSelectedDifferences(prev => {
      const newMap = new Map(prev);
      const hostDiffs = newMap.get(hostId) || new Set();
      
      if (selected) {
        hostDiffs.add(differenceIndex);
      } else {
        hostDiffs.delete(differenceIndex);
      }
      
      if (hostDiffs.size > 0) {
        newMap.set(hostId, hostDiffs);
      } else {
        newMap.delete(hostId);
      }
      
      return newMap;
    });
  };

  // Removed unused function handleSelectAllDifferences

  const handleDeploy = async (deployments: DiffDeployment[]): Promise<BatchDeploymentStatus> => {
    try {
      const result = await diffApi.batchDeploy(deployments);
      
      // Refresh affected hosts
      const hostIds = deployments.map(d => d.host_id);
      const hostNames = hostIds.map(id => {
        const hostDiff = hostDiffs.find(diff => diff.host_id === id);
        return hostDiff?.host.name;
      }).filter(Boolean) as string[];
      const refreshedDiffs = await diffApi.refreshHostDiffs(hostNames);
      setHostDiffs(prev => prev.map(diff => {
        const refreshed = refreshedDiffs.find(r => r.host_id === diff.host_id);
        return refreshed || diff;
      }));
      
      // Clear selections for successfully deployed hosts
      setSelectedDifferences(prev => {
        const newMap = new Map(prev);
        result.results.forEach(res => {
          if (res.success) {
            newMap.delete(res.host_id);
          }
        });
        return newMap;
      });
      
      addNotification({
        type: result.successful_deploys === result.total_hosts ? 'success' : 'warning',
        title: 'Deployment completed',
        message: `${result.successful_deploys}/${result.total_hosts} hosts deployed successfully`,
      });
      
      return result;
    } catch (error) {
      console.error('Deployment failed:', error);
      addNotification({
        type: 'error',
        title: 'Deployment failed',
        message: error instanceof Error ? error.message : 'Unknown error occurred',
      });
      throw error;
    }
  };

  const handleExportReport = async () => {
    try {
      const hostIds = filteredHostDiffs.map(h => h.host_id);
      const blob = await diffApi.exportDiffReport(hostIds, 'html');
      
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `ssh-diff-report-${new Date().toISOString().split('T')[0]}.html`;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
      
      addNotification({
        type: 'success',
        title: 'Report exported',
        message: 'Diff report has been downloaded',
      });
    } catch (error) {
      console.error('Failed to export report:', error);
      addNotification({
        type: 'error',
        title: 'Export failed',
        message: error instanceof Error ? error.message : 'Unknown error occurred',
      });
    }
  };

  // Auto-refresh effect
  useEffect(() => {
    if (!autoRefresh) return;

    const interval = setInterval(() => {
      handleRefreshAll(true); // Silent refresh
    }, refreshInterval);

    return () => clearInterval(interval);
  }, [autoRefresh, refreshInterval, handleRefreshAll]);

  // Load initial data
  useEffect(() => {
    loadHostDiffs();
  }, [loadHostDiffs]);

  // Filter and sort host diffs
  const filteredHostDiffs = React.useMemo(() => {
    return hostDiffs.filter(hostDiff => {
      // Status filter
      if (filters.status !== 'all' && hostDiff.status !== filters.status) {
        return false;
      }
      
      // Search filter
      if (filters.search) {
        const searchLower = filters.search.toLowerCase();
        const searchableText = [
          hostDiff.host.name,
          hostDiff.host.address,
          hostDiff.host.username,
        ].join(' ').toLowerCase();
        
        if (!searchableText.includes(searchLower)) {
          return false;
        }
      }
      
      // Zero diff filter
      if (!filters.show_zero_diff && hostDiff.difference_count === 0) {
        return false;
      }
      
      return true;
    });
  }, [hostDiffs, filters]);

  // Removed unused getStatusIcon function

  const getStatusBadge = (status: HostDiffStatus['status']) => {
    const baseClasses = "inline-flex items-center px-2 py-1 rounded-full text-xs font-medium";
    
    switch (status) {
      case 'synchronized':
        return (
          <span className={cn(baseClasses, "bg-green-100 text-green-800 dark:bg-green-900/20 dark:text-green-400")}>
            <CheckCircle size={12} className="mr-1" />
            Synchronized
          </span>
        );
      case 'out_of_sync':
        return (
          <span className={cn(baseClasses, "bg-yellow-100 text-yellow-800 dark:bg-yellow-900/20 dark:text-yellow-400")}>
            <AlertTriangle size={12} className="mr-1" />
            Out of Sync
          </span>
        );
      case 'error':
        return (
          <span className={cn(baseClasses, "bg-red-100 text-red-800 dark:bg-red-900/20 dark:text-red-400")}>
            <XCircle size={12} className="mr-1" />
            Error
          </span>
        );
      case 'unknown':
        return (
          <span className={cn(baseClasses, "bg-gray-100 text-gray-800 dark:bg-gray-900/20 dark:text-gray-400")}>
            <WifiOff size={12} className="mr-1" />
            Unknown
          </span>
        );
      default:
        return (
          <span className={cn(baseClasses, "bg-gray-100 text-gray-800 dark:bg-gray-900/20 dark:text-gray-400")}>
            <Clock size={12} className="mr-1" />
            Checking...
          </span>
        );
    }
  };

  const selectedHostDiff = selectedHostId ? hostDiffs.find(h => h.host_id === selectedHostId) : null;
  const totalSelectedDifferences = Array.from(selectedDifferences.values())
    .reduce((sum, set) => sum + set.size, 0);

  const columns: Column<HostDiffStatus>[] = [
    {
      key: 'actions',
      header: '',
      width: '50px',
      sortable: false,
      render: (_: unknown, item: HostDiffStatus) => (
        <input
          type="checkbox"
          checked={selectedHosts.has(item.host_id)}
          onChange={(e) => {
            const newSelected = new Set(selectedHosts);
            if (e.target.checked) {
              newSelected.add(item.host_id);
            } else {
              newSelected.delete(item.host_id);
            }
            setSelectedHosts(newSelected);
          }}
          className="rounded border-gray-300 text-blue-600 focus:ring-blue-500"
        />
      ),
    },
    {
      key: 'host',
      header: 'Host',
      render: (_: unknown, item: HostDiffStatus) => (
        <div>
          <div className="font-medium text-gray-900 dark:text-gray-100">
            {item.host.name}
          </div>
          <div className="text-sm text-gray-500 dark:text-gray-400">
            {item.host.address}:{item.host.port}
          </div>
        </div>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      width: '150px',
      render: (_: unknown, item: HostDiffStatus) => getStatusBadge(item.status),
    },
    {
      key: 'difference_count',
      header: 'Differences',
      width: '120px',
      render: (value: unknown) => (
        <div className="text-center">
          {(value as number) === 0 ? (
            <span className="text-green-600 dark:text-green-400 font-medium">0</span>
          ) : (
            <span className="text-yellow-600 dark:text-yellow-400 font-medium">{value as number}</span>
          )}
        </div>
      ),
    },
    {
      key: 'last_checked',
      header: 'Last Checked',
      width: '150px',
      render: (value: unknown) => (
        <span className="text-sm text-gray-600 dark:text-gray-400">
          {(value as string) ? new Date(value as string).toLocaleString() : 'Never'}
        </span>
      ),
    },
    {
      key: 'actions',
      header: 'Actions',
      width: '200px',
      sortable: false,
      render: (_: unknown, item: HostDiffStatus) => (
        <div className="flex items-center space-x-2">
          <Button
            variant="ghost"
            size="sm"
            onClick={() => handleRefreshHost(item.host_id)}
            leftIcon={<RefreshCw size={16} />}
          >
            Refresh
          </Button>
          {item.difference_count > 0 && (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setSelectedHostId(item.host_id)}
              leftIcon={<Eye size={16} />}
            >
              View Diff
            </Button>
          )}
        </div>
      ),
    },
  ];

  if (loading) {
    return (
      <div className="p-6">
        <div className="text-center py-12">
          <Loading size="lg" text="Loading host diff status..." />
        </div>
      </div>
    );
  }

  return (
    <div className="p-6 space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-gray-100">
            SSH Key Diff Viewer
          </h1>
          <p className="text-gray-600 dark:text-gray-400 mt-1">
            Compare expected vs actual authorized_keys files across hosts
          </p>
        </div>
        
        <div className="flex items-center space-x-3">
          <Button
            variant="ghost"
            onClick={handleExportReport}
            leftIcon={<Download size={16} />}
          >
            Export Report
          </Button>
          
          {totalSelectedDifferences > 0 && (
            <Button
              onClick={() => setDeploymentModalOpen(true)}
              leftIcon={<Upload size={16} />}
            >
              Deploy Changes ({totalSelectedDifferences})
            </Button>
          )}
        </div>
      </div>

      {/* Controls */}
      <Card className="p-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center space-x-4">
            {/* Search */}
            <div className="w-80">
              <Input
                type="text"
                placeholder="Search hosts..."
                value={filters.search}
                onChange={(e) => setFilters(prev => ({ ...prev, search: e.target.value }))}
                className="w-full"
              />
            </div>

            {/* Status filter */}
            <select
              value={filters.status}
              onChange={(e) => setFilters(prev => ({ 
                ...prev, 
                status: e.target.value as DiffPageFilters['status'] 
              }))}
              className="px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100"
            >
              <option value="all">All Hosts</option>
              <option value="out_of_sync">Out of Sync</option>
              <option value="error">Error</option>
              <option value="synchronized">Synchronized</option>
            </select>

            {/* Show zero diff toggle */}
            <label className="flex items-center space-x-2">
              <input
                type="checkbox"
                checked={filters.show_zero_diff}
                onChange={(e) => setFilters(prev => ({ ...prev, show_zero_diff: e.target.checked }))}
                className="rounded border-gray-300 text-blue-600 focus:ring-blue-500"
              />
              <span className="text-sm text-gray-700 dark:text-gray-300">Show synchronized hosts</span>
            </label>
          </div>

          <div className="flex items-center space-x-3">
            {/* Auto-refresh toggle */}
            <label className="flex items-center space-x-2">
              <input
                type="checkbox"
                checked={autoRefresh}
                onChange={(e) => setAutoRefresh(e.target.checked)}
                className="rounded border-gray-300 text-blue-600 focus:ring-blue-500"
              />
              <span className="text-sm text-gray-700 dark:text-gray-300">Auto-refresh</span>
              {autoRefresh && (
                <Pause size={16} className="text-blue-600 dark:text-blue-400" />
              )}
            </label>

            {/* Refresh buttons */}
            {selectedHosts.size > 0 && (
              <Button
                variant="ghost"
                onClick={handleRefreshSelected}
                disabled={refreshing}
                leftIcon={<RefreshCw size={16} className={refreshing ? 'animate-spin' : ''} />}
              >
                Refresh Selected
              </Button>
            )}
            
            <Button
              variant="ghost"
              onClick={() => handleRefreshAll()}
              disabled={refreshing}
              leftIcon={<RefreshCw size={16} className={refreshing ? 'animate-spin' : ''} />}
            >
              Refresh All
            </Button>
          </div>
        </div>
      </Card>

      {/* Host Table */}
      <Card className="overflow-hidden">
        <DataTable
          data={filteredHostDiffs}
          columns={columns}
          loading={refreshing}
          searchable={false}
          emptyMessage="No hosts found matching the current filters"
        />
      </Card>

      {/* Detailed Diff View */}
      {selectedHostDiff && (
        <Card className="p-6">
          <div className="flex items-center justify-between mb-6">
            <h2 className="text-xl font-semibold text-gray-900 dark:text-gray-100">
              Detailed Diff: {selectedHostDiff.host.name}
            </h2>
            <Button
              variant="ghost"
              onClick={() => setSelectedHostId(null)}
              leftIcon={<X size={16} />}
            >
              Close
            </Button>
          </div>

          {selectedHostDiff.error_message && (
            <Card className="p-4 mb-6 bg-red-50 dark:bg-red-900/20 border-red-200 dark:border-red-800">
              <div className="flex items-center space-x-2">
                <XCircle size={16} className="text-red-600 dark:text-red-400" />
                <span className="text-red-800 dark:text-red-200 font-medium">Error</span>
              </div>
              <p className="text-red-700 dark:text-red-300 mt-2">
                {selectedHostDiff.error_message}
              </p>
            </Card>
          )}

          {selectedHostDiff.file_diff && (
            <div className="mb-6">
              <DiffViewer
                fileDiff={selectedHostDiff.file_diff}
                hostName={selectedHostDiff.host.name}
              />
            </div>
          )}

          {selectedHostDiff.key_differences && selectedHostDiff.key_differences.length > 0 && (
            <KeyDiffTable
              differences={selectedHostDiff.key_differences}
              hostName={selectedHostDiff.host.name}
              selectable={true}
              onSelectDifference={(diff, selected) => {
                const index = selectedHostDiff.key_differences?.indexOf(diff) ?? -1;
                if (index >= 0) {
                  handleSelectDifference(selectedHostDiff.host_id, index, selected);
                }
              }}
              selectedDifferences={selectedDifferences.get(selectedHostDiff.host_id) || new Set()}
              showDetails={true}
            />
          )}
        </Card>
      )}

      {/* Deployment Modal */}
      <DeploymentModal
        isOpen={deploymentModalOpen}
        onClose={() => setDeploymentModalOpen(false)}
        hostDiffs={hostDiffs.filter(h => selectedDifferences.has(h.host_id))}
        selectedDifferences={selectedDifferences}
        onDeploy={handleDeploy}
      />
    </div>
  );
};

export default DiffPage;