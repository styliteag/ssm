import React, { useState, useEffect, useCallback, useMemo } from 'react';
import { useLocation } from 'react-router-dom';
import { 
  Server, 
  Plus, 
  Edit2, 
  Trash2, 
  Activity, 
  AlertCircle, 
  CheckCircle, 
  Users,
  Key,
  Globe,
  Filter,
  Ban
} from 'lucide-react';
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Button,
  DataTable,
  Modal,
  Form,
  Tooltip,
  type Column,
  type FormField
} from '../components/ui';
import { useNotifications } from '../contexts/NotificationContext';
import { hostsService } from '../services/api/hosts';
import HostEditModal from '../components/HostEditModal';
import BulkEditModal, { type BulkUpdateData } from '../components/BulkEditModal';
import type { 
  Host, 
  HostFormData
} from '../types';

interface ExtendedHost extends Host {
  lastTested?: Date;
  [key: string]: unknown;
}

const HostsPage: React.FC = () => {
  const location = useLocation();
  const { showSuccess, showError } = useNotifications();
  
  
  // State management
  const [hosts, setHosts] = useState<ExtendedHost[]>([]);
  const [jumpHosts, setJumpHosts] = useState<Host[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedHost, setSelectedHost] = useState<ExtendedHost | null>(null);
  const [statusFilter, setStatusFilter] = useState<'active' | 'all' | 'online' | 'offline' | 'error' | 'unknown' | 'disabled'>('active');
  
  // Selection state for multiselect
  const [selectedHosts, setSelectedHosts] = useState<ExtendedHost[]>([]);
  
  // Modal states
  const [showAddModal, setShowAddModal] = useState(false);
  const [showEditModal, setShowEditModal] = useState(false);
  const [showDeleteModal, setShowDeleteModal] = useState(false);
  const [showBulkEditModal, setShowBulkEditModal] = useState(false);
  
  // Form loading states
  const [submitting, setSubmitting] = useState(false);
  const [testing, setTesting] = useState<Record<number, boolean>>({});


  // Poll individual host statuses in parallel batches - only poll hosts that need updating
  const pollHostStatuses = useCallback(async (hostsList: ExtendedHost[], forceAll: boolean = false) => {
    const batchSize = 10;
    const now = new Date();
    const maxAge = 5 * 60 * 1000; // 5 minutes

    // Filter hosts that need polling
    const hostsToPoll = hostsList.filter(host => {
      if (host.disabled) return false; // Skip disabled hosts
      if (forceAll) return true; // Force polling all if requested
      if (!host.lastTested) return true; // Never tested
      if (host.connection_status === 'unknown') return true; // Unknown status
      const age = now.getTime() - host.lastTested.getTime();
      return age > maxAge; // Older than 5 minutes
    });

    if (hostsToPoll.length === 0) {
      console.log('No hosts need polling');
      return;
    }

    console.log(`Polling ${hostsToPoll.length} out of ${hostsList.length} hosts`);

    // Process hosts in batches of 10
    for (let i = 0; i < hostsToPoll.length; i += batchSize) {
      const batch = hostsToPoll.slice(i, i + batchSize);

      // Poll this batch in parallel
      const promises = batch.map(async (host) => {
        try {
          const response = await hostsService.getHostByName(host.name);
          if (response.success && response.data) {
            const updatedHost = { ...response.data!, lastTested: new Date() };
            // Only update if status actually changed
            setHosts(prev => prev.map(h =>
              h.id === host.id
                ? (h.connection_status !== updatedHost.connection_status ||
                   h.connection_error !== updatedHost.connection_error ||
                   !h.lastTested)
                  ? updatedHost
                  : h
                : h
            ));
          } else {
            // API returned error - update host with error status
            console.error('API error for host', host.name, response.message);
            const errorMessage = response.message || 'API request failed';
            setHosts(prev => prev.map(h =>
              h.id === host.id
                ? (h.connection_status !== 'error' || h.connection_error !== errorMessage)
                  ? {
                      ...h,
                      connection_status: 'error',
                      connection_error: errorMessage,
                      lastTested: new Date()
                    }
                  : h
                : h
            ));
          }
        } catch (error) {
          console.error('Failed to poll status for host', host.name, error);
          // Update host with network/request error
          const errorMessage = `Polling failed: ${error instanceof Error ? error.message : 'Network error'}`;
          setHosts(prev => prev.map(h =>
            h.id === host.id
              ? (h.connection_status !== 'error' || h.connection_error !== errorMessage)
                ? {
                    ...h,
                    connection_status: 'error',
                    connection_error: errorMessage,
                    lastTested: new Date()
                  }
                : h
              : h
          ));
        }
      });

      // Wait for this batch to complete before starting the next batch
      await Promise.allSettled(promises);

      // Small delay between batches to prevent overwhelming the backend
      if (i + batchSize < hostsToPoll.length) {
        await new Promise(resolve => setTimeout(resolve, 200));
      }
    }
  }, []);

  // Load hosts on component mount
  const loadHosts = useCallback(async () => {
    try {
      setLoading(true);
      const response = await hostsService.getHosts();
      if (response.success && response.data) {
        // Host data includes basic info with "unknown" status - will be updated individually
        const hostsWithUnknownStatus = response.data.items.map(host => ({ 
          ...host, 
          lastTested: new Date() 
        }));
        setHosts(hostsWithUnknownStatus);
        
        // Start polling individual host statuses in background
        pollHostStatuses(hostsWithUnknownStatus, true); // Force polling for initial load
      }
    } catch {
      showError('Failed to load hosts', 'Please try again later');
    } finally {
      setLoading(false);
    }
  }, [showError, pollHostStatuses]);

  // Load jump hosts for dropdown - reuse hosts data to avoid duplicate API calls
  const loadJumpHosts = useCallback(async () => {
    try {
      // Only fetch if hosts list is empty, otherwise reuse existing data
      if (hosts.length > 0) {
        setJumpHosts(hosts);
        return;
      }
      
      const response = await hostsService.getAllHosts();
      if (response.success && response.data) {
        setJumpHosts(response.data);
      }
    } catch (error) {
      console.error('Failed to load jump hosts:', error);
    }
  }, [hosts]);

  useEffect(() => {
    loadHosts();
  }, [loadHosts]);

  // Periodic background refresh of host statuses
  useEffect(() => {
    if (hosts.length === 0) return;

    const interval = setInterval(() => {
      // Only poll hosts that haven't been tested recently
      pollHostStatuses(hosts, false);
    }, 2 * 60 * 1000); // Every 2 minutes

    return () => clearInterval(interval);
  }, [hosts, pollHostStatuses]);

  // Load jump hosts after hosts are loaded to reuse data
  useEffect(() => {
    if (hosts.length > 0) {
      loadJumpHosts();
    }
  }, [hosts.length, loadJumpHosts]);

  // Test SSH connection
  const testConnection = useCallback(async (host: ExtendedHost) => {
    // Skip testing for disabled hosts
    if (host.disabled) {
      showError('Host is disabled', `Cannot test connection to disabled host ${host.name}`);
      return;
    }

    try {
      setTesting(prev => ({ ...prev, [host.id]: true }));

      // Force update by testing SSH connection directly (bypasses cache)
      const testResponse = await hostsService.getHostLogins(host.name, true);

      if (testResponse.success && testResponse.data) {
        // Connection successful - update host status
        const updatedHost = {
          ...host,
          connection_status: 'online' as const,
          connection_error: undefined,
          lastTested: new Date()
        };

        setHosts(prev => prev.map(h =>
          h.id === host.id ? updatedHost : h
        ));

        showSuccess('Connection successful', `Successfully connected to ${host.name}. Found ${testResponse.data.length} available logins.`);
      } else {
        // Connection failed - update host status
        const errorMsg = testResponse.message || 'Unable to connect to host';
        const updatedHost = {
          ...host,
          connection_status: 'error' as const,
          connection_error: errorMsg,
          lastTested: new Date()
        };

        setHosts(prev => prev.map(h =>
          h.id === host.id ? updatedHost : h
        ));

        showError('Connection failed', errorMsg);
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Connection failed';
      const updatedHost = {
        ...host,
        connection_status: 'error' as const,
        connection_error: errorMessage,
        lastTested: new Date()
      };

      setHosts(prev => prev.map(h =>
        h.id === host.id ? updatedHost : h
      ));

      showError('Connection test failed', errorMessage);
    } finally {
      setTesting(prev => ({ ...prev, [host.id]: false }));
    }
  }, [showSuccess, showError]);

  // Form field definitions for add host modal
  const getFormFields = (): FormField[] => [
    {
      name: 'name',
      label: 'Host Name',
      type: 'text',
      required: true,
      placeholder: 'Enter a unique name for this host',
      helperText: 'A friendly name to identify this host',
      validation: {
        minLength: 2,
        maxLength: 50,
        pattern: /^[a-zA-Z0-9\-_.]+$/,
        custom: (value: unknown) => {
          const exists = hosts.some(h => 
            h.name.toLowerCase() === (value as string).toLowerCase()
          );
          return exists ? 'Host name already exists' : null;
        }
      }
    },
    {
      name: 'address',
      label: 'Hostname/IP Address',
      type: 'text',
      required: true,
      placeholder: 'example.com or 192.168.1.100',
      helperText: 'The hostname or IP address of the SSH server'
    },
    {
      name: 'port',
      label: 'SSH Port',
      type: 'number',
      required: true,
      placeholder: '22',
      helperText: 'SSH port (typically 22)',
      validation: {
        min: 1,
        max: 65535
      }
    },
    {
      name: 'username',
      label: 'SSH Username',
      type: 'text',
      required: true,
      placeholder: 'root or ubuntu',
      helperText: 'Username for SSH authentication'
    },
    {
      name: 'key_fingerprint',
      label: 'SSH Key Fingerprint',
      type: 'text',
      placeholder: 'SHA256:...',
      helperText: 'Optional: Expected SSH host key fingerprint for verification'
    },
    {
      name: 'jump_via',
      label: 'Jump Host',
      type: 'select',
      placeholder: 'Select a jump host (optional)',
      helperText: 'Optional: Use another host as a jump/bastion host',
      options: [
        { value: '', label: 'None (no jump host)' },
        ...jumpHosts.map(host => ({
          value: host.id,
          label: `${host.name} (${host.address})`
        }))
      ]
    },
    {
      name: 'disabled',
      label: 'Disabled',
      type: 'checkbox',
      helperText: 'When disabled, no SSH connections will be made to this host'
    },
    {
      name: 'comment',
      label: 'Comment',
      type: 'text',
      placeholder: 'Optional comment about this host',
      helperText: 'Add any notes or comments about this host'
    }
  ];

  // Handle form submissions
  const handleAddHost = async (values: HostFormData) => {
    try {
      setSubmitting(true);
      const hostData = {
        name: values.name,
        address: values.address,
        port: Number(values.port),
        username: values.username,
        jump_via: values.jump_via && String(values.jump_via) !== '' ? Number(values.jump_via) : null,
        key_fingerprint: values.key_fingerprint && values.key_fingerprint.trim() !== '' ? values.key_fingerprint : null,
        disabled: values.disabled || false,
        comment: values.comment && values.comment.trim() !== '' ? values.comment.trim() : null
      };

      console.log('Creating host with data:', hostData);
      const response = await hostsService.createHost({
        ...hostData,
        jump_via: hostData.jump_via ?? undefined,
        key_fingerprint: hostData.key_fingerprint ?? undefined,
        disabled: hostData.disabled,
        comment: hostData.comment ?? undefined
      });
      console.log('Host creation response:', response);
      
      if (response.success && response.data) {
        // Check if this is a host key confirmation response (two-step process)
        if (response.data.requires_confirmation) {
          console.log('Host key confirmation required, sending with fingerprint');
          
          // Second call with the received fingerprint
          const confirmedHostData = {
            ...hostData,
            key_fingerprint: response.data.key_fingerprint
          };
          
          const finalResponse = await hostsService.createHost({
            ...confirmedHostData,
            jump_via: confirmedHostData.jump_via ?? undefined,
            key_fingerprint: confirmedHostData.key_fingerprint ?? undefined,
            disabled: confirmedHostData.disabled
          });
          console.log('Final host creation response:', finalResponse);
          
          if (finalResponse.success && finalResponse.data) {
            setHosts(prev => [...prev, { 
              ...finalResponse.data!, 
              connectionStatus: 'unknown' 
            }]);
            setShowAddModal(false);
            showSuccess('Host added', `${finalResponse.data!.name} has been added successfully`);
            // Jump hosts will be updated automatically via useEffect when hosts change
          } else {
            console.error('Final host creation failed:', finalResponse);
            showError('Failed to add host', finalResponse.message || 'Failed to confirm host key');
          }
        } else {
          // Direct host creation (when fingerprint was provided)
          setHosts(prev => [...prev, { 
            ...response.data!, 
            connectionStatus: 'unknown' 
          }]);
          setShowAddModal(false);
          showSuccess('Host added', `${response.data!.name} has been added successfully`);
          // Jump hosts will be updated automatically via useEffect when hosts change
        }
      } else {
        console.error('Host creation failed:', response);
        showError('Failed to add host', response.message || 'Please check your input and try again');
      }
    } catch (error) {
      console.error('Host creation error:', error);
      showError('Failed to add host', 'Please check your input and try again');
    } finally {
      setSubmitting(false);
    }
  };

  // Handle host updated callback from edit modal
  const handleHostUpdated = () => {
    setSelectedHost(null);
    setShowEditModal(false);
    // Instead of reloading all hosts, just refresh the specific host that was edited
    if (selectedHost) {
      refreshSingleHost(selectedHost.name);
    }
  };

  // Refresh a single host without reloading the entire list
  const refreshSingleHost = useCallback(async (hostName: string) => {
    try {
      const response = await hostsService.getHostByName(hostName);
      if (response.success && response.data) {
        const updatedHost = { ...response.data!, lastTested: new Date() };
        setHosts(prev => prev.map(h =>
          h.id === updatedHost.id ? updatedHost : h
        ));
        // Update jump hosts if this host is used as a jump host
        setJumpHosts(prev => prev.map(h =>
          h.id === updatedHost.id ? updatedHost : h
        ));
      }
    } catch (error) {
      console.error('Failed to refresh host:', hostName, error);
    }
  }, []);

  const handleDeleteHost = async () => {
    if (!selectedHost) return;

    try {
      setSubmitting(true);
      const response = await hostsService.deleteHost(selectedHost.name);
      if (response.success) {
        setHosts(prev => prev.filter(h => h.id !== selectedHost.id));
        setShowDeleteModal(false);
        setSelectedHost(null);
        showSuccess('Host deleted', `${selectedHost.name} has been deleted successfully`);
        // Jump hosts will be updated automatically via useEffect when hosts change
      }
    } catch {
      showError('Failed to delete host', 'Please try again later');
    } finally {
      setSubmitting(false);
    }
  };

  // Handle bulk update
  const handleBulkUpdate = async (updateData: BulkUpdateData) => {
    if (selectedHosts.length === 0) return;

    try {
      // Process hosts sequentially to avoid database lock contention
      const results = [];
      for (const host of selectedHosts) {
        // Create clean update payload with only the fields the backend expects
        const hostUpdate: Partial<Host> = {
          name: host.name,
          username: host.username,
          address: host.address,
          port: host.port,
          // Include key_fingerprint as it's required by the backend
          key_fingerprint: host.key_fingerprint || '',
          // Keep existing values for fields we're not updating
          jump_via: host.jump_via,
          disabled: host.disabled,
        };

        // Apply bulk changes only to fields that were specified
        if (updateData.jump_via !== undefined) {
          hostUpdate.jump_via = updateData.jump_via ?? undefined;
        }
        if (updateData.disabled !== undefined) {
          hostUpdate.disabled = updateData.disabled;
        }

        try {
          const result = await hostsService.updateHost(host.name, hostUpdate as Host);
          results.push(result);
          
          // Invalidate cache for the updated host
          if (result.success) {
            try {
              await hostsService.invalidateCache(host.name);
            } catch (cacheError) {
              console.warn(`Failed to invalidate cache for ${host.name}:`, cacheError);
              // Don't fail the operation if cache invalidation fails
            }
          }
        } catch (error) {
          console.error(`Failed to update host ${host.name}:`, error);
          results.push({ success: false, message: `Failed to update ${host.name}` });
        }
      }
      const successCount = results.filter(r => r.success).length;
      const failureCount = results.length - successCount;

      if (successCount > 0) {
        showSuccess(
          'Bulk update completed', 
          `Successfully updated ${successCount} host${successCount !== 1 ? 's' : ''}${
            failureCount > 0 ? `. ${failureCount} update${failureCount !== 1 ? 's' : ''} failed.` : ''
          }`
        );
        
        // Refresh only the updated hosts instead of reloading everything
        selectedHosts.forEach(host => {
          refreshSingleHost(host.name);
        });
        
        // Clear selection
        setSelectedHosts([]);
      } else {
        showError('Bulk update failed', 'All updates failed. Please try again.');
      }
    } catch (error) {
      console.error('Bulk update error:', error);
      showError('Bulk update failed', 'Please try again later');
    }
  };

  // Helper function to get host status, considering disabled state first
  const getHostStatus = (host: ExtendedHost): 'online' | 'offline' | 'error' | 'unknown' | 'disabled' => {
    // Disabled state takes precedence over connection status
    if (host.disabled) return 'disabled';
    
    // Then check connection status
    if (host.connection_status === 'online') return 'online';
    if (host.connection_status === 'offline') return 'offline';
    if (host.connection_status === 'error') return 'error';
    return 'unknown';
  };

  // Filter hosts based on status
  const filteredHosts = useMemo(() => {
    if (statusFilter === 'all') return hosts;
    if (statusFilter === 'active') return hosts.filter(host => !host.disabled);
    return hosts.filter(host => getHostStatus(host) === statusFilter);
  }, [hosts, statusFilter]);

  // Status filter options with counts
  const statusFilterOptions = useMemo(() => [
    { value: 'active', label: 'Active Hosts', count: hosts.filter(h => !h.disabled).length },
    { value: 'all', label: 'All Hosts', count: hosts.length },
    { value: 'online', label: 'Online', count: hosts.filter(h => getHostStatus(h) === 'online').length },
    { value: 'offline', label: 'Offline', count: hosts.filter(h => getHostStatus(h) === 'offline').length },
    { value: 'error', label: 'Error', count: hosts.filter(h => getHostStatus(h) === 'error').length },
    { value: 'unknown', label: 'Unknown', count: hosts.filter(h => getHostStatus(h) === 'unknown').length },
    { value: 'disabled', label: 'Disabled', count: hosts.filter(h => getHostStatus(h) === 'disabled').length },
  ], [hosts]);

  // Create tooltip content for each host - using memoized function to prevent re-renders
  const getTooltipContent = useCallback((host: ExtendedHost) => (
    <div className="space-y-3 max-w-md">
      {/* Host Info */}
      <div className="border-b border-gray-600 pb-2">
        <h4 className="font-semibold text-white flex items-center gap-2">
          <Server size={16} className="flex-shrink-0" />
          <span style={{ wordBreak: 'break-word' }}>{host.name}</span>
        </h4>
        <p className="text-gray-300 text-xs flex items-center gap-1">
          <Globe size={12} className="flex-shrink-0" />
          <span style={{ wordBreak: 'break-word' }}>{host.address}:{host.port}</span>
        </p>
        {host.comment && (
          <p className="text-gray-300 text-xs mt-1" style={{ wordBreak: 'break-word' }}>
            <span className="font-medium">Comment:</span> {host.comment}
          </p>
        )}
      </div>

      {/* Connection Status */}
      <div>
        <div className="flex items-center gap-2 mb-1">
          {host.connection_status === 'online' && <CheckCircle size={14} className="text-green-400" />}
          {host.connection_status === 'offline' && <AlertCircle size={14} className="text-red-400" />}
          {host.connection_status === 'error' && <AlertCircle size={14} className="text-orange-400" />}
          {(!host.connection_status || host.connection_status === 'unknown') && <Activity size={14} className="text-gray-400" />}

          <span className="font-medium">
            {host.connection_status === 'online' && 'Online'}
            {host.connection_status === 'offline' && 'Offline'}
            {host.connection_status === 'error' && 'Error'}
            {(!host.connection_status || host.connection_status === 'unknown') && 'Unknown'}
          </span>
        </div>

        {host.lastTested && (
          <p className="text-gray-400 text-xs">
            Last tested: {host.lastTested.toLocaleString()}
          </p>
        )}

        {host.connection_error && (
          <div className="text-red-400 text-xs mt-1">
            <div className="flex items-start gap-1" style={{ maxWidth: '100%' }}>
              <span className="flex-shrink-0">❌</span>
              <span
                className="flex-1"
                style={{
                  wordBreak: 'break-word',
                  overflowWrap: 'anywhere',
                  minWidth: 0,
                  maxWidth: '100%'
                }}
              >
                {host.connection_error}
              </span>
            </div>
          </div>
        )}
      </div>

      {/* SSH Info */}
      <div>
        <div className="flex items-center gap-2 mb-1">
          <Key size={14} />
          <span className="font-medium">SSH Details</span>
        </div>
        <div className="text-xs text-gray-300 space-y-1" style={{ maxWidth: '100%' }}>
          <div style={{ wordBreak: 'break-word' }}>User: <code className="bg-gray-700 px-1 rounded">{host.username}</code></div>
          {host.key_fingerprint && (
            <div style={{ wordBreak: 'break-word' }}>
              Fingerprint: <code className="bg-gray-700 px-1 rounded text-xs" style={{ wordBreak: 'break-all' }}>
                {host.key_fingerprint.slice(0, 20)}...
              </code>
            </div>
          )}
          {host.jumphost_name && (
            <div style={{ wordBreak: 'break-word' }}>Jump host: {host.jumphost_name}</div>
          )}
        </div>
      </div>

      {/* Authorized Users */}
      {host.authorizations && host.authorizations.length > 0 && (
        <div>
          <div className="flex items-center gap-2 mb-1">
            <Users size={14} />
            <span className="font-medium">Authorized Users ({host.authorizations.length})</span>
          </div>
          <div className="text-xs text-gray-300 space-y-1 max-h-20 overflow-y-auto">
            {host.authorizations.map((auth, index) => (
              <div key={auth.id || index} className="flex justify-between gap-2" style={{ alignItems: 'flex-start' }}>
                <span style={{ wordBreak: 'break-word', flex: 1 }}>{auth.username}</span>
                <code className="bg-gray-700 px-1 rounded flex-shrink-0" style={{ fontSize: '10px' }}>{auth.login}</code>
              </div>
            ))}
          </div>
        </div>
      )}

      {host.authorizations && host.authorizations.length === 0 && (
        <div>
          <div className="flex items-center gap-2 mb-1">
            <Users size={14} />
            <span className="font-medium">Authorized Users</span>
          </div>
          <p className="text-gray-400 text-xs">No authorized users</p>
        </div>
      )}
    </div>
  ), []);

  // Table column definitions
  const columns: Column<ExtendedHost>[] = [
    {
      key: 'name',
      header: 'Name',
      sortable: true,
      render: (value, host) => (
        <button
          className="font-medium text-gray-900 dark:text-gray-100 hover:text-blue-600 dark:hover:text-blue-400 text-left cursor-pointer"
          onClick={(e) => {
            e.stopPropagation();
            setSelectedHost(host);
            setShowEditModal(true);
          }}
          title="Click to edit host"
        >
          {value as string}
        </button>
      )
    },
    {
      key: 'address',
      header: 'Address',
      sortable: true,
      render: (value, host) => (
        <div className="text-gray-600 dark:text-gray-400">
          {value as string}:{(host as ExtendedHost).port}
        </div>
      )
    },
    {
      key: 'username',
      header: 'Username',
      sortable: true,
      render: (value) => (
        <code className="text-sm bg-gray-100 dark:bg-gray-800 px-2 py-1 rounded">
          {value as string}
        </code>
      )
    },
    {
      key: 'connection_status',
      header: 'Status',
      sortable: true,
      render: (_, host) => {
        const icons = {
          online: <CheckCircle size={16} className="text-green-500" />,
          offline: <AlertCircle size={16} className="text-red-500" />,
          error: <AlertCircle size={16} className="text-orange-500" />,
          unknown: <Activity size={16} className="text-gray-400" />,
          disabled: <Ban size={16} className="text-gray-500" />
        };

        const labels = {
          online: 'Online',
          offline: 'Offline',
          error: 'Error',
          unknown: 'Unknown',
          disabled: 'Disabled'
        };

        const colors = {
          online: 'text-green-700 bg-green-50 dark:text-green-400 dark:bg-green-900/20',
          offline: 'text-red-700 bg-red-50 dark:text-red-400 dark:bg-red-900/20',
          error: 'text-orange-700 bg-orange-50 dark:text-orange-400 dark:bg-orange-900/20',
          unknown: 'text-gray-700 bg-gray-50 dark:text-gray-400 dark:bg-gray-900/20',
          disabled: 'text-gray-500 bg-gray-100 dark:text-gray-500 dark:bg-gray-800'
        };

        // Use the helper function to get status, considering disabled state first
        const currentStatus = getHostStatus(host);
        return (
          <Tooltip
            content={getTooltipContent(host)}
            position="top"
            delay={300}
            className="max-w-md"
          >
            <div className={`inline-flex items-center space-x-1 px-2 py-1 rounded-full text-xs font-medium cursor-pointer ${colors[currentStatus]}`}>
              {icons[currentStatus]}
              <span>{labels[currentStatus]}</span>
            </div>
          </Tooltip>
        );
      }
    },
    {
      key: 'jumphost_name',
      header: 'Jump Host',
      render: (jumpHostName: unknown) => {
        return jumpHostName ? (
          <span className="text-sm text-gray-600 dark:text-gray-400">
            {String(jumpHostName)}
          </span>
        ) : (
          <span className="text-gray-400">—</span>
        );
      }
    },
    {
      key: 'actions',
      header: 'Actions',
      render: (_, host) => (
        <div className="flex items-center space-x-2">
          <Button
            variant="ghost"
            size="sm"
            onClick={(e) => {
              e.stopPropagation();
              testConnection(host);
            }}
            disabled={testing[host.id]}
            loading={testing[host.id]}
            title="Test SSH connection"
          >
            <Activity size={16} />
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={(e) => {
              e.stopPropagation();
              setSelectedHost(host);
              setShowEditModal(true);
            }}
            title="Edit host"
          >
            <Edit2 size={16} />
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={(e) => {
              e.stopPropagation();
              setSelectedHost(host);
              setShowDeleteModal(true);
            }}
            title="Delete host"
          >
            <Trash2 size={16} />
          </Button>
        </div>
      )
    }
  ];

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white flex items-center space-x-2">
            <Server size={24} />
            <span>Hosts</span>
          </h1>
          <p className="text-gray-600 dark:text-gray-400">
            Manage SSH hosts and their configurations
          </p>
        </div>
        <div className="flex items-center space-x-3">
          {/* Bulk actions - show when hosts are selected */}
          {selectedHosts.length > 0 && (
            <div className="flex items-center space-x-2">
              <span className="text-sm text-gray-600 dark:text-gray-400">
                {selectedHosts.length} host{selectedHosts.length !== 1 ? 's' : ''} selected
              </span>
              <Button 
                variant="secondary"
                size="sm"
                onClick={() => setShowBulkEditModal(true)}
                leftIcon={<Edit2 size={16} />}
              >
                Bulk Edit
              </Button>
              <Button 
                variant="ghost"
                size="sm"
                onClick={() => setSelectedHosts([])}
              >
                Clear
              </Button>
            </div>
          )}
          <Button onClick={() => setShowAddModal(true)} leftIcon={<Plus size={16} />}>
            Add Host
          </Button>
        </div>
      </div>

      {/* Host List */}
      <Card>
        <CardHeader>
          <div className="flex items-center justify-between">
            <CardTitle>SSH Hosts ({filteredHosts.length}{statusFilter !== 'all' ? ` of ${hosts.length}` : ''})</CardTitle>
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
        <CardContent className="overflow-visible">
          <div className="overflow-visible">
            <DataTable
              data={filteredHosts}
              columns={columns}
              loading={loading}
              emptyMessage={
                statusFilter === 'all' ? "No hosts found. Add your first SSH host to get started." :
                statusFilter === 'active' ? "No active hosts found. Add your first SSH host or check the disabled hosts filter." :
                `No hosts with status '${statusFilterOptions.find(o => o.value === statusFilter)?.label || statusFilter}'.`
              }
              searchPlaceholder="Search hosts by name, address, or username..."
              initialSort={{ key: 'name', direction: 'asc' }}
              initialSearch={(location.state as { searchTerm?: string })?.searchTerm || ''}
              // Selection props
              selectable={true}
              selectedItems={selectedHosts}
              onSelectionChange={setSelectedHosts}
              getItemId={(host) => host.id}
            />
          </div>
        </CardContent>
      </Card>

      {/* Add Host Modal */}
      <Modal
        isOpen={showAddModal}
        onClose={() => setShowAddModal(false)}
        title="Add New Host"
        size="lg"
      >
        <Form
          fields={getFormFields()}
          onSubmit={(values) => handleAddHost(values as unknown as HostFormData)}
          submitText="Add Host"
          cancelText="Cancel"
          onCancel={() => setShowAddModal(false)}
          loading={submitting}
          layout="grid"
          gridCols={2}
          initialValues={{
            port: 22
          }}
        />
      </Modal>

      {/* Edit Host Modal */}
      <HostEditModal
        isOpen={showEditModal}
        onClose={() => {
          setShowEditModal(false);
          setSelectedHost(null);
        }}
        host={selectedHost}
        onHostUpdated={handleHostUpdated}
        jumpHosts={jumpHosts}
      />

      {/* Delete Confirmation Modal */}
      <Modal
        isOpen={showDeleteModal}
        onClose={() => {
          setShowDeleteModal(false);
          setSelectedHost(null);
        }}
        title="Delete Host"
        size="md"
      >
        {selectedHost && (
          <div className="space-y-4">
            <div className="flex items-start space-x-3">
              <AlertCircle className="text-red-500 mt-1" size={20} />
              <div>
                <p className="text-gray-900 dark:text-gray-100">
                  Are you sure you want to delete <strong>{selectedHost.name}</strong>?
                </p>
                <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                  This action cannot be undone. All authorizations and configurations for this host will be permanently removed.
                </p>
              </div>
            </div>
            
            <div className="bg-gray-50 dark:bg-gray-800 p-3 rounded-md">
              <div className="text-sm space-y-1 text-gray-900 dark:text-gray-100">
                <div><strong>Name:</strong> {selectedHost.name}</div>
                <div><strong>Address:</strong> {selectedHost.address}:{selectedHost.port}</div>
                <div><strong>Username:</strong> {selectedHost.username}</div>
              </div>
            </div>

            <div className="flex items-center justify-end space-x-3">
              <Button
                variant="secondary"
                onClick={() => {
                  setShowDeleteModal(false);
                  setSelectedHost(null);
                }}
                disabled={submitting}
              >
                Cancel
              </Button>
              <Button
                variant="danger"
                onClick={handleDeleteHost}
                loading={submitting}
              >
                Delete Host
              </Button>
            </div>
          </div>
        )}
      </Modal>

      {/* Bulk Edit Modal */}
      <BulkEditModal
        isOpen={showBulkEditModal}
        onClose={() => setShowBulkEditModal(false)}
        selectedHosts={selectedHosts}
        jumpHosts={jumpHosts}
        onBulkUpdate={handleBulkUpdate}
      />
    </div>
  );
};

export default HostsPage;