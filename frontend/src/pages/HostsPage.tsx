import React, { useState, useEffect, useCallback, useRef, useMemo } from 'react';
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
  type Column,
  type FormField
} from '../components/ui';
import { useNotifications } from '../contexts/NotificationContext';
import { hostsService } from '../services/api/hosts';
import HostEditModal from '../components/HostEditModal';
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
  
  // Modal states
  const [showAddModal, setShowAddModal] = useState(false);
  const [showEditModal, setShowEditModal] = useState(false);
  const [showDeleteModal, setShowDeleteModal] = useState(false);
  
  // Form loading states
  const [submitting, setSubmitting] = useState(false);
  const [testing, setTesting] = useState<Record<number, boolean>>({});

  // Refresh host status by fetching updated host details
  const refreshHostStatus = useCallback(async (host: ExtendedHost) => {
    try {
      const response = await hostsService.getHostByName(host.name);
      if (response.success && response.data) {
        setHosts(prev => prev.map(h => 
          h.id === host.id 
            ? { ...response.data!, lastTested: new Date() }
            : h
        ));
      }
    } catch (error) {
      console.error('Failed to refresh host status for', host.name, error);
    }
  }, []);

  // Poll individual host statuses in parallel batches
  const pollHostStatuses = useCallback(async (hostsList: ExtendedHost[]) => {
    const batchSize = 10;
    
    // Process hosts in batches of 10
    for (let i = 0; i < hostsList.length; i += batchSize) {
      const batch = hostsList.slice(i, i + batchSize);
      
      // Poll this batch in parallel
      const promises = batch.map(async (host) => {
        // Skip polling for disabled hosts - they already have correct status from backend
        if (host.disabled) {
          return;
        }
        try {
          const response = await hostsService.getHostByName(host.name);
          if (response.success && response.data) {
            setHosts(prev => prev.map(h => 
              h.id === host.id 
                ? { ...response.data!, lastTested: new Date() }
                : h
            ));
          } else {
            // API returned error - update host with error status
            console.error('API error for host', host.name, response.message);
            setHosts(prev => prev.map(h => 
              h.id === host.id 
                ? { 
                    ...h, 
                    connection_status: 'error',
                    connection_error: response.message || 'API request failed',
                    lastTested: new Date() 
                  }
                : h
            ));
          }
        } catch (error) {
          console.error('Failed to poll status for host', host.name, error);
          // Update host with network/request error
          const errorMessage = error instanceof Error ? error.message : 'Network error';
          setHosts(prev => prev.map(h => 
            h.id === host.id 
              ? { 
                  ...h, 
                  connection_status: 'error',
                  connection_error: `Polling failed: ${errorMessage}`,
                  lastTested: new Date() 
                }
              : h
          ));
        }
      });
      
      // Wait for this batch to complete before starting the next batch
      await Promise.allSettled(promises);
      
      // Small delay between batches to prevent overwhelming the backend
      if (i + batchSize < hostsList.length) {
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
        pollHostStatuses(hostsWithUnknownStatus);
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
      
      // Refresh host data which includes updated connection status
      await refreshHostStatus(host);
      
      // Get the updated host to check its status
      const updatedResponse = await hostsService.getHostByName(host.name);
      if (updatedResponse.success && updatedResponse.data) {
        const updatedHost = updatedResponse.data;
        if (updatedHost.connection_status === 'online') {
          showSuccess('Connection successful', `Successfully connected to ${host.name}`);
        } else {
          const errorMsg = updatedHost.connection_error || 'Unable to connect to host';
          showError('Connection failed', errorMsg);
        }
      }
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : 'Connection failed';
      showError('Connection test failed', errorMessage);
    } finally {
      setTesting(prev => ({ ...prev, [host.id]: false }));
    }
  }, [showSuccess, showError, refreshHostStatus]);

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
        disabled: values.disabled || false
      };

      console.log('Creating host with data:', hostData);
      const response = await hostsService.createHost({
        ...hostData,
        jump_via: hostData.jump_via ?? undefined,
        key_fingerprint: hostData.key_fingerprint ?? undefined,
        disabled: hostData.disabled
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
    // Refresh the hosts list to get updated data
    loadHosts();
    // Jump hosts will be updated automatically via useEffect when hosts change
  };

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

  // Host Status Tooltip Component
  const HostStatusTooltip: React.FC<{ host: ExtendedHost; children: React.ReactNode }> = ({ host, children }) => {
    const [isVisible, setIsVisible] = useState(false);
    const [position, setPosition] = useState({ x: 0, y: 0 });
    const triggerRef = useRef<HTMLDivElement>(null);
    const timeoutRef = useRef<NodeJS.Timeout | null>(null);

    const handleMouseEnter = useCallback(() => {
      if (triggerRef.current) {
        const rect = triggerRef.current.getBoundingClientRect();
        setPosition({
          x: rect.left + rect.width / 2,
          y: rect.top - 8
        });
      }
      timeoutRef.current = setTimeout(() => setIsVisible(true), 100) as NodeJS.Timeout;
    }, []);

    const handleMouseLeave = useCallback(() => {
      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current);
      }
      setIsVisible(false);
    }, []);

    useEffect(() => {
      return () => {
        if (timeoutRef.current) {
          clearTimeout(timeoutRef.current);
        }
      };
    }, []);

    return (
      <>
        <div 
          ref={triggerRef}
          onMouseEnter={handleMouseEnter}
          onMouseLeave={handleMouseLeave}
          className="p-1 -m-1"
        >
          {children}
        </div>
        
        {/* Portal tooltip rendered at document body level */}
        {isVisible && (
          <div 
            className="fixed bg-gray-900 dark:bg-gray-800 text-white text-sm rounded-lg shadow-xl border border-gray-700 p-4 pointer-events-none transition-opacity duration-200"
            style={{
              left: `${position.x}px`,
              top: `${position.y}px`,
              transform: 'translateX(-50%) translateY(-100%)',
              zIndex: 99999,
              width: '480px',
              maxWidth: '480px'
            }}
          >
            {/* Arrow */}
            <div className="absolute top-full left-1/2 transform -translate-x-1/2 w-0 h-0 border-l-4 border-r-4 border-t-4 border-transparent border-t-gray-900 dark:border-t-gray-800"></div>
            
            {/* Host Info */}
            <div className="space-y-3">
              <div className="border-b border-gray-700 pb-2">
                <h4 className="font-semibold text-white flex items-center gap-2">
                  <Server size={16} className="flex-shrink-0" />
                  <span style={{ wordBreak: 'break-word' }}>{host.name}</span>
                </h4>
                <p className="text-gray-300 text-xs flex items-center gap-1">
                  <Globe size={12} className="flex-shrink-0" />
                  <span style={{ wordBreak: 'break-word' }}>{host.address}:{host.port}</span>
                </p>
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
                  <div style={{ wordBreak: 'break-word' }}>User: <code className="bg-gray-800 px-1 rounded">{host.username}</code></div>
                  {host.key_fingerprint && (
                    <div style={{ wordBreak: 'break-word' }}>
                      Fingerprint: <code className="bg-gray-800 px-1 rounded text-xs" style={{ wordBreak: 'break-all' }}>
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
                        <code className="bg-gray-800 px-1 rounded flex-shrink-0" style={{ fontSize: '10px' }}>{auth.login}</code>
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
          </div>
        )}
      </>
    );
  };

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
      // Custom sort value to ensure disabled hosts are sorted correctly
      sortValue: (host: ExtendedHost) => {
        const status = getHostStatus(host);
        // Define sort order: disabled first, then error, offline, unknown, online
        const sortOrder = {
          disabled: 0,
          error: 1,
          offline: 2,
          unknown: 3,
          online: 4
        };
        return sortOrder[status];
      },
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
          <HostStatusTooltip host={host}>
            <div className={`inline-flex items-center space-x-1 px-2 py-1 rounded-full text-xs font-medium cursor-pointer ${colors[currentStatus]}`}>
              {icons[currentStatus]}
              <span>{labels[currentStatus]}</span>
            </div>
          </HostStatusTooltip>
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
        <Button onClick={() => setShowAddModal(true)} leftIcon={<Plus size={16} />}>
          Add Host
        </Button>
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
    </div>
  );
};

export default HostsPage;