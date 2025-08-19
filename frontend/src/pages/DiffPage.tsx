import React, { useState, useEffect, useMemo } from 'react';
import { Activity, RefreshCw, Upload, Filter, Edit2 } from 'lucide-react';
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Button,
  DataTable,
  Modal,
  type Column
} from '../components/ui';
import { diffApi, DiffHost, DetailedDiffResponse } from '../services/api/diff';
import { hostsService } from '../services/api/hosts';
import type { Host } from '../types';
import DiffIssue from '../components/DiffIssue';
import HostEditModal from '../components/HostEditModal';
import { useNotifications } from '../contexts/NotificationContext';

const DiffPage: React.FC = () => {
  const { showSuccess, showError } = useNotifications();
  const [hosts, setHosts] = useState<DiffHost[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedHost, setSelectedHost] = useState<DiffHost | null>(null);
  const [hostDetails, setHostDetails] = useState<DetailedDiffResponse | null>(null);
  const [detailsLoading, setDetailsLoading] = useState(false);
  const [showModal, setShowModal] = useState(false);
  const [modalError, setModalError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<'all' | 'synchronized' | 'needs-sync' | 'error' | 'loading'>('all');
  
  // Edit modal state
  const [showEditModal, setShowEditModal] = useState(false);
  const [editingHost, setEditingHost] = useState<Host | null>(null);
  const [jumpHosts, setJumpHosts] = useState<Host[]>([]);

  useEffect(() => {
    const fetchHosts = async () => {
      try {
        setLoading(true);
        const hostData = await diffApi.getAllHosts();
        
        // Mark all hosts as loading diff data initially
        const hostsWithLoading = hostData.map(host => ({ ...host, loading: true }));
        setHosts(hostsWithLoading);
        setLoading(false);

        // Fetch diff data for each host in the background
        fetchDiffDataForHosts(hostData);
      } catch (err) {
        showError('Failed to load hosts', 'Please try again later');
        console.error('Error fetching hosts:', err);
        setLoading(false);
      }
    };

    const fetchDiffDataForHosts = async (hosts: DiffHost[]) => {
      // Process hosts in batches to avoid overwhelming the server
      const batchSize = 5;
      
      for (let i = 0; i < hosts.length; i += batchSize) {
        const batch = hosts.slice(i, i + batchSize);
        
        // Process batch in parallel
        const promises = batch.map(async (host) => {
          try {
            const diffData = await diffApi.getHostDiff(host.name);
            
            // Update the specific host with diff data
            setHosts(prevHosts => 
              prevHosts.map(h => 
                h.id === host.id 
                  ? { 
                      ...h, 
                      diff_summary: diffData.diff_summary,
                      is_empty: diffData.is_empty,
                      total_items: diffData.total_items,
                      loading: false 
                    }
                  : h
              )
            );
          } catch (err) {
            console.error(`Error fetching diff for ${host.name}:`, err);
            
            // Extract error message from backend
            const errorMessage = err instanceof Error ? err.message : 'Failed to load diff';
            
            // Update host with error state
            setHosts(prevHosts => 
              prevHosts.map(h => 
                h.id === host.id 
                  ? { ...h, loading: false, error: errorMessage }
                  : h
              )
            );
          }
        });

        await Promise.all(promises);
        
        // Small delay between batches to be nice to the server
        if (i + batchSize < hosts.length) {
          await new Promise(resolve => setTimeout(resolve, 100));
        }
      }
    };

    fetchHosts();
    loadJumpHosts();
  }, [showError]);

  // Load jump hosts for dropdown
  const loadJumpHosts = async () => {
    try {
      const response = await hostsService.getAllHosts();
      if (response.success && response.data) {
        setJumpHosts(response.data);
      }
    } catch (error) {
      console.error('Failed to load jump hosts:', error);
    }
  };

  // Handle host updated callback from modal
  const handleHostUpdated = (updatedHost: Host) => {
    setEditingHost(null);
    // Update the host in the list
    setHosts(prev => prev.map(h => 
      h.id === updatedHost.id 
        ? { ...h, name: updatedHost.name, address: updatedHost.address }
        : h
    ));
  };

  const handleHostClick = async (host: DiffHost) => {
    setSelectedHost(host);
    setShowModal(true);
    setDetailsLoading(true);
    setModalError(null);
    
    try {
      // Fetch detailed diff information
      const hostDetails = await diffApi.getHostDiffDetails(host.name);
      setHostDetails(hostDetails);
    } catch (err) {
      console.error('Error fetching host details:', err);
      showError('Failed to load host details', 'Please try again later');
      // Store the error message for display in the modal
      const errorMessage = err instanceof Error ? err.message : 'Failed to load host details';
      setModalError(errorMessage);
      setHostDetails(null);
    } finally {
      setDetailsLoading(false);
    }
  };

  const handleRefreshHost = async () => {
    if (!selectedHost) return;
    
    setDetailsLoading(true);
    setModalError(null);
    try {
      const hostDetails = await diffApi.getHostDiffDetails(selectedHost.name, true); // Force update
      setHostDetails(hostDetails);
      showSuccess('Data refreshed', 'Host diff data has been updated');
    } catch (err) {
      console.error('Error refreshing host details:', err);
      showError('Failed to refresh data', 'Please try again later');
      // Store the error message for display in the modal
      const errorMessage = err instanceof Error ? err.message : 'Failed to refresh data';
      setModalError(errorMessage);
    } finally {
      setDetailsLoading(false);
    }
  };

  const closeModal = () => {
    setSelectedHost(null);
    setHostDetails(null);
    setShowModal(false);
    setModalError(null);
  };

  // Table column definitions
  const columns: Column<DiffHost>[] = [
    {
      key: 'name',
      header: 'Name',
      sortable: true,
      render: (value, host) => (
        <div className="flex items-center space-x-2">
          <span className="font-medium text-gray-900 dark:text-gray-100">
            {value as string}
          </span>
          <Button
            variant="ghost"
            size="sm"
            onClick={async (e) => {
              e.stopPropagation();
              try {
                // Fetch full host details
                const response = await hostsService.getHostByName(host.name);
                if (response.success && response.data) {
                  setEditingHost(response.data);
                  setShowEditModal(true);
                } else {
                  showError('Failed to load host details', 'Please try again');
                }
              } catch (error) {
                console.error('Error fetching host details:', error);
                showError('Failed to load host details', 'Please try again');
              }
            }}
            title="Edit host"
            className="p-1 h-auto hover:bg-gray-100 dark:hover:bg-gray-700"
          >
            <Edit2 size={14} className="text-gray-400 hover:text-gray-600 dark:text-gray-500 dark:hover:text-gray-300" />
          </Button>
        </div>
      )
    },
    {
      key: 'address',
      header: 'Address',
      sortable: true,
      render: (value) => (
        <div className="text-gray-600 dark:text-gray-400">
          {value as string}
        </div>
      )
    },
    {
      key: 'loading',
      header: 'Status',
      render: (_, host) => {
        if (host.loading) {
          return (
            <div className="flex items-center space-x-2">
              <RefreshCw className="w-4 h-4 animate-spin text-blue-500" />
              <span className="text-gray-500 dark:text-gray-400">Loading...</span>
            </div>
          );
        }
        
        if (host.error) {
          return (
            <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 dark:bg-red-900/30 text-red-800 dark:text-red-300">
              Error
            </span>
          );
        }
        
        if (host.is_empty === false) {
          return (
            <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 dark:bg-red-900/30 text-red-800 dark:text-red-300">
              Needs Sync
            </span>
          );
        }
        
        if (host.is_empty === true) {
          return (
            <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 dark:bg-green-900/30 text-green-800 dark:text-green-300">
              Synchronized
            </span>
          );
        }
        
        return (
          <span className="text-gray-400 dark:text-gray-500">Unknown</span>
        );
      }
    },
    {
      key: 'total_items',
      header: 'Differences',
      render: (_, host) => {
        if (host.loading) return '-';
        if (host.error) return 'Error';
        if (host.total_items !== undefined) {
          return (
            <span className={host.total_items > 0 ? 'text-red-600 dark:text-red-300 font-medium' : 'text-gray-500 dark:text-gray-400'}>
              {host.total_items} {host.total_items === 1 ? 'difference' : 'differences'}
            </span>
          );
        }
        return '-';
      }
    }
  ];

  // Helper function to get host status
  const getHostStatus = (host: DiffHost): 'synchronized' | 'needs-sync' | 'error' | 'loading' => {
    if (host.loading) return 'loading';
    if (host.error) return 'error';
    if (host.is_empty === false) return 'needs-sync';
    if (host.is_empty === true) return 'synchronized';
    return 'loading';
  };

  // Filter hosts based on status
  const filteredHosts = useMemo(() => {
    if (statusFilter === 'all') return hosts;
    return hosts.filter(host => getHostStatus(host) === statusFilter);
  }, [hosts, statusFilter]);

  // Status filter options
  const statusFilterOptions = [
    { value: 'all', label: 'All Status', count: hosts.length },
    { value: 'synchronized', label: 'Synchronized', count: hosts.filter(h => getHostStatus(h) === 'synchronized').length },
    { value: 'needs-sync', label: 'Needs Sync', count: hosts.filter(h => getHostStatus(h) === 'needs-sync').length },
    { value: 'error', label: 'Error', count: hosts.filter(h => getHostStatus(h) === 'error').length },
    { value: 'loading', label: 'Loading', count: hosts.filter(h => getHostStatus(h) === 'loading').length },
  ];

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white flex items-center space-x-2">
            <Activity size={24} />
            <span>Hosts Diff Overview</span>
          </h1>
          <p className="text-gray-600 dark:text-gray-400">
            Monitor SSH key synchronization status across all hosts
          </p>
        </div>
      </div>

      {/* Host List */}
      <Card>
        <CardHeader>
          <div className="flex items-center justify-between">
            <CardTitle>SSH Hosts Diff Status ({filteredHosts.length}{statusFilter !== 'all' ? ` of ${hosts.length}` : ''})</CardTitle>
            <div className="flex items-center space-x-2">
              <Filter size={16} className="text-gray-500 dark:text-gray-400" />
              <select
                value={statusFilter}
                onChange={(e) => setStatusFilter(e.target.value as typeof statusFilter)}
                className="h-8 px-3 py-1 text-sm border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
              >
                {statusFilterOptions.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label} ({option.count})
                  </option>
                ))}
              </select>
            </div>
          </div>
        </CardHeader>
        <CardContent>
          <DataTable
            data={filteredHosts}
            columns={columns}
            loading={loading}
            emptyMessage={statusFilter === 'all' ? "No hosts found. Please check your host configuration." : `No hosts with status '${statusFilterOptions.find(o => o.value === statusFilter)?.label || statusFilter}'.`}
            searchPlaceholder="Search hosts by name or address..."
            initialSort={{ key: 'name', direction: 'asc' }}
            onRowClick={(host) => handleHostClick(host)}
          />
        </CardContent>
      </Card>

      {/* Host Details Modal */}
      <Modal
        isOpen={showModal}
        onClose={closeModal}
        title={`Host Details: ${selectedHost?.name || ''}`}
        size="full"
      >
        {detailsLoading ? (
          <div className="flex items-center justify-center py-8">
            <RefreshCw className="w-8 h-8 animate-spin text-blue-500" />
            <span className="ml-3">Loading host details...</span>
          </div>
        ) : !hostDetails ? (
          <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4">
            <div className="flex items-start space-x-3">
              <div className="text-red-600 dark:text-red-400">
                <svg className="w-5 h-5" fill="currentColor" viewBox="0 0 20 20">
                  <path fillRule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7 4a1 1 0 11-2 0 1 1 0 012 0zm-1-9a1 1 0 00-1 1v4a1 1 0 102 0V6a1 1 0 00-1-1z" clipRule="evenodd" />
                </svg>
              </div>
              <div>
                <h4 className="text-red-800 dark:text-red-200 font-medium">Failed to load host details</h4>
                <p className="text-red-700 dark:text-red-300 text-sm mt-1">
                  {modalError || 'Please try again later'}
                </p>
              </div>
            </div>
          </div>
        ) : (
          <div className="space-y-5">
            {/* Basic Host Information */}
            <div className="bg-white dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700 p-4">
              <h3 className="text-lg font-semibold text-gray-900 dark:text-gray-100 mb-3 border-b border-gray-200 dark:border-gray-700 pb-2">Host Information</h3>
              <div className="grid grid-cols-4 gap-4">
                <div className="flex flex-col">
                  <span className="text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide">ID</span>
                  <span className="text-sm font-semibold text-gray-900 dark:text-gray-100 mt-1">{hostDetails.host.id}</span>
                </div>
                <div className="flex flex-col">
                  <span className="text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide">Name</span>
                  <span className="text-sm font-semibold text-gray-900 dark:text-gray-100 mt-1">{hostDetails.host.name}</span>
                </div>
                <div className="flex flex-col">
                  <span className="text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide">Address</span>
                  <span className="text-sm font-semibold text-gray-900 dark:text-gray-100 mt-1">{hostDetails.host.address}</span>
                </div>
                <div className="flex flex-col">
                  <span className="text-xs font-medium text-gray-500 dark:text-gray-400 uppercase tracking-wide">Last Updated</span>
                  <span className="text-sm font-semibold text-gray-900 dark:text-gray-100 mt-1">
                    {new Date(hostDetails.cache_timestamp).toLocaleString()}
                  </span>
                </div>
              </div>
            </div>

            {/* Summary */}
            <div className="bg-white dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700 p-4">
              <h3 className="text-lg font-semibold text-gray-900 dark:text-gray-100 mb-3 border-b border-gray-200 dark:border-gray-700 pb-2">Status Summary</h3>
              <div className="flex items-center justify-between mb-3">
                <span className={`inline-flex items-center px-3 py-1.5 rounded-full text-sm font-semibold ${
                  hostDetails.logins.length === 0 
                    ? 'bg-green-100 dark:bg-green-900/30 text-green-800 dark:text-green-300 border border-green-200 dark:border-green-800' 
                    : 'bg-red-100 dark:bg-red-900/30 text-red-800 dark:text-red-300 border border-red-200 dark:border-red-800'
                }`}>
                  {hostDetails.logins.length === 0 ? '✓ Synchronized' : '⚠ Needs Sync'}
                </span>
                <div className="text-sm text-gray-600 dark:text-gray-400 bg-gray-100 dark:bg-gray-800 px-3 py-1 rounded-full">
                  {hostDetails.expected_keys.length} expected keys
                </div>
              </div>
              <p className="text-sm text-gray-700 dark:text-gray-300 leading-relaxed">{hostDetails.summary}</p>
            </div>

            {/* Expected Keys */}
            {hostDetails.expected_keys.length > 0 && (
              <div className="bg-white dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700 p-4">
                <h3 className="text-lg font-semibold text-gray-900 dark:text-gray-100 mb-3 border-b border-gray-200 dark:border-gray-700 pb-2">Expected Keys</h3>
                <div className="max-h-40 overflow-y-auto">
                  <div className="grid grid-cols-2 gap-3">
                    {hostDetails.expected_keys.map((key, index) => (
                      <div key={index} className="bg-gray-50 dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg p-3 hover:bg-gray-100 dark:hover:bg-gray-750 transition-colors">
                        <div className="flex justify-between items-start mb-2">
                          <div className="truncate">
                            <span className="font-semibold text-gray-900 dark:text-gray-100 text-sm">{key.username}</span> 
                            <span className="text-gray-600 dark:text-gray-400 text-sm"> → {key.login}</span>
                            {key.comment && <span className="text-gray-500 dark:text-gray-400 ml-1 text-xs">({key.comment})</span>}
                          </div>
                          <span className="text-xs bg-blue-100 dark:bg-blue-900/50 text-blue-800 dark:text-blue-200 px-2 py-1 rounded-full ml-2 flex-shrink-0 font-medium">
                            {key.key_type}
                          </span>
                        </div>
                        {key.options && (
                          <div className="text-xs text-gray-600 dark:text-gray-400 font-mono bg-gray-100 dark:bg-gray-700 p-1 rounded truncate">
                            Options: {key.options}
                          </div>
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            )}

            {/* Detailed Issues */}
            {hostDetails.logins.length > 0 && (
              <div className="bg-white dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700 p-4">
                <h3 className="text-lg font-semibold text-gray-900 dark:text-gray-100 mb-3 border-b border-gray-200 dark:border-gray-700 pb-2">Issues Found</h3>
                <div className="space-y-4">
                  {hostDetails.logins.map((loginDiff, loginIndex) => (
                    <div key={loginIndex} className="bg-gray-50 dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg overflow-hidden">
                      <div className="bg-gradient-to-r from-gray-100 to-gray-50 dark:from-gray-800 dark:to-gray-750 px-4 py-3 border-b border-gray-200 dark:border-gray-700">
                        <div className="flex items-center justify-between">
                          <h4 className="text-sm font-semibold text-gray-900 dark:text-gray-100 flex items-center">
                            <span className="text-gray-600 dark:text-gray-400 mr-2">Login:</span>
                            <code className="bg-blue-100 dark:bg-blue-900/50 text-blue-800 dark:text-blue-200 px-2 py-1 rounded-md text-xs font-bold">{loginDiff.login}</code>
                          </h4>
                          <span className="text-xs text-gray-600 dark:text-gray-400 bg-white dark:bg-gray-700 px-2 py-1 rounded-full font-medium">
                            {loginDiff.issues.length} issue{loginDiff.issues.length !== 1 ? 's' : ''}
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
                      <div className="p-4 bg-white dark:bg-gray-900">
                        <div className="grid grid-cols-3 gap-3">
                          {loginDiff.issues.map((issue, issueIndex) => (
                            <div key={issueIndex} className="min-w-0">
                              <div className="bg-gray-50 dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg p-2 hover:shadow-sm transition-shadow">
                                <DiffIssue issue={issue} />
                              </div>
                            </div>
                          ))}
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {/* Actions */}
            <div className="bg-gray-50 dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 p-4">
              <div className="flex justify-between items-center">
                <div className="text-sm text-gray-600 dark:text-gray-400">
                  <span className="font-medium">Ready to apply changes?</span>
                </div>
                <div className="flex space-x-3">
                  <Button 
                    onClick={handleRefreshHost}
                    loading={detailsLoading}
                    leftIcon={<RefreshCw size={16} />}
                    variant="secondary"
                    className="font-medium"
                  >
                    Refresh Data
                  </Button>
                  {hostDetails.logins.length > 0 && (
                    <Button 
                      variant="primary"
                      leftIcon={<Upload size={16} />}
                      className="bg-blue-600 hover:bg-blue-700 font-medium px-6"
                    >
                      Sync Keys
                    </Button>
                  )}
                </div>
              </div>
            </div>
          </div>
        )}
      </Modal>

      {/* Edit Host Modal */}
      <HostEditModal
        isOpen={showEditModal}
        onClose={() => {
          setShowEditModal(false);
          setEditingHost(null);
        }}
        host={editingHost}
        onHostUpdated={handleHostUpdated}
        jumpHosts={jumpHosts}
      />
    </div>
  );
};

export default DiffPage;