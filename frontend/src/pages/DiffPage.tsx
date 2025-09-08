import React, { useState, useEffect, useMemo } from 'react';
import { Activity, RefreshCw, Upload, Filter, Edit2, Ban } from 'lucide-react';
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Button,
  DataTable,
  Modal,
  Tooltip,
  type Column
} from '../components/ui';
import { diffApi, DiffHost, DetailedDiffResponse, DiffItemResponse } from '../services/api/diff';
import { usersService } from '../services/api/users';
import { hostsService } from '../services/api/hosts';
import { authorizationsService } from '../services/api/authorizations';
import type { Host, User, UserFormData } from '../types';
import DiffIssue from '../components/DiffIssue';
import HostEditModal from '../components/HostEditModal';
import SyncModal from '../components/SyncModal';
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
  const [statusFilter, setStatusFilter] = useState<'active' | 'all' | 'synchronized' | 'needs-sync' | 'error' | 'loading' | 'disabled'>('active');
  
  // Edit modal state
  const [showEditModal, setShowEditModal] = useState(false);
  const [editingHost, setEditingHost] = useState<Host | null>(null);
  const [jumpHosts, setJumpHosts] = useState<Host[]>([]);
  
  // Unknown key assignment modal state
  const [showUnknownKeyModal, setShowUnknownKeyModal] = useState(false);
  const [unknownKeyIssue, setUnknownKeyIssue] = useState<DiffItemResponse | null>(null);
  const [allUsers, setAllUsers] = useState<User[]>([]);
  
  // Sync modal state
  const [showSyncModal, setShowSyncModal] = useState(false);


  useEffect(() => {
    const fetchHosts = async () => {
      try {
        setLoading(true);
        const hostData = await diffApi.getAllHosts();
        
        // Mark only enabled hosts as loading diff data initially
        const hostsWithLoading = hostData.map(host => ({ 
          ...host, 
          loading: !host.disabled,
          // Set disabled hosts with final state immediately and clear any error state
          ...(host.disabled && {
            diff_summary: 'Host is disabled',
            is_empty: true,
            total_items: 0,
            error: undefined // Clear any error state for disabled hosts
          })
        }));
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
      // Filter out disabled hosts - they're already handled with final state
      const enabledHosts = hosts.filter(host => !host.disabled);
      
      if (enabledHosts.length === 0) return;
      
      // Process enabled hosts in batches to avoid overwhelming the server
      const batchSize = 5;
      
      for (let i = 0; i < enabledHosts.length; i += batchSize) {
        const batch = enabledHosts.slice(i, i + batchSize);
        
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
        if (i + batchSize < enabledHosts.length) {
          await new Promise(resolve => setTimeout(resolve, 100));
        }
      }
    };

    fetchHosts();
    loadJumpHosts();
    loadAllUsers();
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

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

  // Load all users for dropdown
  const loadAllUsers = async () => {
    try {
      const response = await usersService.getAllUsers();
      if (response.success && response.data) {
        setAllUsers(response.data);
      }
    } catch (error) {
      console.error('Failed to load users:', error);
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
    
    // Skip diff operations for disabled hosts
    if (host.disabled) {
      setHostDetails({
        host,
        cache_timestamp: new Date().toISOString(),
        summary: 'Host is disabled - no diff operations available',
        expected_keys: [],
        logins: []
      });
      setDetailsLoading(false);
      return;
    }
    
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
    
    // Cannot refresh disabled hosts
    if (selectedHost.disabled) {
      showError('Host is disabled', 'Cannot refresh diff data for disabled hosts');
      return;
    }
    
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

  // Handle allowing unauthorized keys
  const handleAllowKey = async (issue: DiffItemResponse) => {
    if (!selectedHost || !hostDetails) return;
    
    // Cannot authorize keys on disabled hosts
    if (selectedHost.disabled) {
      showError('Host is disabled', 'Cannot authorize keys on disabled hosts');
      return;
    }
    
    // Extract username from the issue details
    const username = issue.details?.username;
    if (!username) {
      showError('Cannot authorize key', 'Username not found in issue details');
      return;
    }

    // Find the login from the current login section
    const currentLogin = hostDetails.logins.find(login => 
      login.issues.some(i => i === issue)
    )?.login;
    
    if (!currentLogin) {
      showError('Cannot authorize key', 'Login not found for this issue');
      return;
    }

    try {
      // Call the API to authorize the key
      await diffApi.authorizeKey(
        selectedHost.name, 
        username, 
        currentLogin,
        issue.details?.key?.options || undefined
      );
      
      showSuccess('Key authorized', `Key for user "${username}" has been authorized for login "${currentLogin}"`);
      
      // Refresh the host details to show updated status
      const refreshedDetails = await diffApi.getHostDiffDetails(selectedHost.name, true);
      setHostDetails(refreshedDetails);
    } catch (error) {
      console.error('Error allowing key:', error);
      const errorMessage = error instanceof Error ? error.message : 'Please try again later';
      showError('Failed to authorize key', errorMessage);
    }
  };

  // Handle adding unknown keys to existing or new users
  const handleAddUnknownKey = (issue: DiffItemResponse) => {
    setUnknownKeyIssue(issue);
    setShowUnknownKeyModal(true);
  };

  // Handle assigning unknown key to existing user
  const handleAssignToExistingUser = async (userId: number) => {
    if (!unknownKeyIssue || !unknownKeyIssue.details?.key || !selectedHost || !hostDetails) return;

    // Cannot assign keys on disabled hosts
    if (selectedHost.disabled) {
      showError('Host is disabled', 'Cannot assign keys on disabled hosts');
      return;
    }

    // Find the login from the current login section where the unknown key issue is
    const currentLogin = hostDetails.logins.find(login => 
      login.issues.some(i => i === unknownKeyIssue)
    )?.login;
    
    if (!currentLogin) {
      showError('Cannot assign key', 'Login not found for this unknown key');
      return;
    }

    try {
      const keyData = {
        user_id: userId,
        key_type: unknownKeyIssue.details.key.key_type,
        key_base64: unknownKeyIssue.details.key.base64,
        key_comment: unknownKeyIssue.details.key.comment || null
      };

      // Try to assign the key to the user
      let keyAssigned = false;
      try {
        await usersService.assignKeyToUser(keyData);
        keyAssigned = true;
      } catch (keyError) {
        // Key might already exist, which means it's already assigned to a user
        const errorMessage = keyError instanceof Error ? keyError.message : String(keyError);
        console.log('Caught key assignment error:', errorMessage);
        
        // Check for database error message from backend
        if (errorMessage.includes('database error') || 
            errorMessage.includes('UNIQUE constraint') || 
            errorMessage.includes('already exists') || 
            errorMessage.includes('key_base64')) {
          console.log('Key already exists in the system');
          // Don't re-throw, just continue without the key assigned
        } else {
          throw keyError; // Re-throw if it's a different error
        }
      }
      
      // Also create authorization to add the user to this host (if not already exists)
      const authData = {
        host_id: selectedHost.id,
        user_id: userId,
        login: currentLogin,
        options: unknownKeyIssue.details.key.options || undefined
      };
      
      let authorizationCreated = false;
      try {
        await authorizationsService.createAuthorization(authData);
        authorizationCreated = true;
      } catch (authError) {
        // Authorization might already exist, which is fine
        console.log('Authorization might already exist:', authError);
      }
      
      const selectedUser = allUsers.find(u => u.id === userId);
      
      // Construct appropriate success message based on what actually happened
      if (keyAssigned && authorizationCreated) {
        showSuccess('Key assigned and user added to host', `Key has been assigned to user "${selectedUser?.username}" and user has been added to host "${selectedHost.name}"`);
      } else if (keyAssigned && !authorizationCreated) {
        showSuccess('Key assigned', `Key has been assigned to user "${selectedUser?.username}" (user was already authorized on this host)`);
      } else if (!keyAssigned && authorizationCreated) {
        showSuccess('User added to host', `User "${selectedUser?.username}" has been added to host "${selectedHost.name}" (key was already assigned)`);
      } else {
        showSuccess('No changes needed', `User "${selectedUser?.username}" already has this key and is already authorized on this host`);
      }
      
      setShowUnknownKeyModal(false);
      setUnknownKeyIssue(null);
      
      // Refresh the host details to show updated status
      const refreshedDetails = await diffApi.getHostDiffDetails(selectedHost.name, true);
      setHostDetails(refreshedDetails);
    } catch (error) {
      console.error('Error assigning key to user:', error);
      const errorMessage = error instanceof Error ? error.message : 'Please try again later';
      showError('Failed to assign key', errorMessage);
    }
  };

  // Handle syncing SSH keys to host
  const handleSyncKeys = async () => {
    if (!selectedHost || !hostDetails) return;
    
    // Cannot sync keys to disabled hosts
    if (selectedHost.disabled) {
      showError('Host is disabled', 'Cannot sync keys to disabled hosts');
      return;
    }
    
    try {
      // Apply the sync changes
      await diffApi.syncKeys(selectedHost.name);
      
      showSuccess('Keys synchronized', `SSH keys have been synchronized to ${selectedHost.name}`);
      
      // Refresh the host details to show updated status
      const refreshedDetails = await diffApi.getHostDiffDetails(selectedHost.name, true);
      setHostDetails(refreshedDetails);
      
      // Update the host in the list to reflect synchronized status
      setHosts(prev => prev.map(h => 
        h.id === selectedHost.id 
          ? { ...h, is_empty: true, total_items: 0, diff_summary: "No differences found" }
          : h
      ));
    } catch (error) {
      console.error('Error syncing keys:', error);
      const errorMessage = error instanceof Error ? error.message : 'Please try again later';
      showError('Failed to sync keys', errorMessage);
    }
  };

  // Handle creating new user with unknown key
  const handleCreateNewUser = async () => {
    if (!unknownKeyIssue || !unknownKeyIssue.details?.key || !selectedHost || !hostDetails) return;

    // Cannot create users with keys on disabled hosts
    if (selectedHost.disabled) {
      showError('Host is disabled', 'Cannot create users with keys on disabled hosts');
      return;
    }

    // Find the login from the current login section where the unknown key issue is
    const currentLogin = hostDetails.logins.find(login => 
      login.issues.some(i => i === unknownKeyIssue)
    )?.login;
    
    if (!currentLogin) {
      showError('Cannot create user', 'Login not found for this unknown key');
      return;
    }

    const keyComment = unknownKeyIssue.details.key.comment;
    if (!keyComment || keyComment.trim() === '') {
      showError('Cannot create user', 'Key comment is empty. Please provide a username.');
      return;
    }

    try {
      // Validate and clean username
      const cleanUsername = keyComment.trim();
      
      // Basic username validation
      if (cleanUsername.length < 2) {
        showError('Invalid username', 'Username must be at least 2 characters long.');
        return;
      }
      
      if (!/^[a-zA-Z0-9._-]+$/.test(cleanUsername)) {
        showError('Invalid username', 'Username can only contain letters, numbers, dots, underscores, and hyphens.');
        return;
      }
      
      // Check if user already exists
      const existingUser = allUsers.find(u => u.username.toLowerCase() === cleanUsername.toLowerCase());
      
      if (existingUser) {
        showError('Username already exists', `User "${cleanUsername}" already exists. Please assign the key to the existing user instead.`);
        return;
      }

      // Create new user with key comment as username
      const userData: UserFormData = {
        username: cleanUsername,
        enabled: true
      };

      const userResponse = await usersService.createUser(userData);
      console.log('Full user creation response:', userResponse);
      console.log('User data from response:', userResponse.data);
      
      if (!userResponse.success || !userResponse.data) {
        // Provide more specific error messaging
        let errorMsg = userResponse.message || 'Failed to create user';
        if (errorMsg.includes('database error') || errorMsg.includes('constraint')) {
          errorMsg = `User "${cleanUsername}" might already exist or contain invalid characters. Please try a different username.`;
        }
        throw new Error(errorMsg);
      }

      // The backend returns username in 'id' field, we need to find the actual numeric ID
      // Fetch the user list again to get the newly created user with proper ID
      const freshUsersResponse = await usersService.getAllUsers();
      if (!freshUsersResponse.success || !freshUsersResponse.data) {
        throw new Error('Could not fetch users to find the newly created user');
      }
      
      // Find the newly created user to get the proper numeric ID
      const newUser = freshUsersResponse.data.find(u => u.username === cleanUsername);
      
      if (!newUser) {
        throw new Error('User was created but could not be found to assign the key');
      }

      console.log('Found created user:', newUser);

      // Assign the key to the new user
      const keyData = {
        user_id: newUser.id, // Use the proper numeric ID
        key_type: unknownKeyIssue.details.key.key_type,
        key_base64: unknownKeyIssue.details.key.base64,
        key_comment: unknownKeyIssue.details.key.comment || null
      };
      console.log('Key data being sent:', keyData);
      console.log('user_id type:', typeof keyData.user_id, 'value:', keyData.user_id);

      let keyAssigned = false;
      try {
        await usersService.assignKeyToUser(keyData);
        keyAssigned = true;
      } catch (keyError) {
        // For a new user, key shouldn't already exist, but handle gracefully
        const errorMessage = keyError instanceof Error ? keyError.message : String(keyError);
        console.log('Caught key assignment error:', errorMessage);
        
        // Check for database error message from backend
        if (errorMessage.includes('database error') || 
            errorMessage.includes('UNIQUE constraint') || 
            errorMessage.includes('already exists') || 
            errorMessage.includes('key_base64')) {
          console.log('Key already exists in the system - this is unexpected for a new user');
          showError('Key already exists', 'This key is already assigned to another user. The new user was created but the key could not be assigned.');
          // Don't re-throw, just continue without the key assigned
        } else {
          throw keyError; // Re-throw if it's a different error
        }
      }
      
      // Also create authorization to add the user to this host (only if key was assigned)
      if (keyAssigned) {
        const authData = {
          host_id: selectedHost.id,
          user_id: newUser.id,
          login: currentLogin,
          options: unknownKeyIssue.details.key.options || undefined
        };
        
        try {
          await authorizationsService.createAuthorization(authData);
          showSuccess('User created and added to host', `New user "${userData.username}" has been created with the key and added to host "${selectedHost.name}"`);
        } catch (authError) {
          // This shouldn't happen for new users, but handle gracefully
          console.log('Could not create authorization for new user:', authError);
          showSuccess('User created', `New user "${userData.username}" has been created with the key`);
        }
      } else {
        // If key wasn't assigned (already exists), just notify about user creation
        showSuccess('User created', `New user "${userData.username}" has been created (key already exists in system)`);
      }
      
      setShowUnknownKeyModal(false);
      setUnknownKeyIssue(null);
      
      // Refresh users list and host details
      await loadAllUsers();
      const refreshedDetails = await diffApi.getHostDiffDetails(selectedHost.name, true);
      setHostDetails(refreshedDetails);
    } catch (error) {
      console.error('Error creating user with key:', error);
      const errorMessage = error instanceof Error ? error.message : 'Please try again later';
      showError('Failed to create user', errorMessage);
    }
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
        if (host.disabled) {
          return (
            <Tooltip
              content="This host is disabled and will not be checked for SSH key synchronization"
              position="top"
            >
              <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-gray-100 dark:bg-gray-800/50 text-gray-600 dark:text-gray-400 cursor-help">
                <Ban className="w-3 h-3 mr-1" />
                Disabled
              </span>
            </Tooltip>
          );
        }

        if (host.loading) {
          return (
            <Tooltip
              content="Checking SSH connection and fetching authorized keys from the host"
              position="top"
            >
              <div className="flex items-center space-x-2 cursor-help">
                <RefreshCw className="w-4 h-4 animate-spin text-blue-500" />
                <span className="text-gray-500 dark:text-gray-400">Loading...</span>
              </div>
            </Tooltip>
          );
        }
        
        if (host.error) {
          return (
            <Tooltip 
              content={
                <div className="space-y-1">
                  <div className="font-semibold">Connection Error</div>
                  <div className="text-xs">{host.error}</div>
                </div>
              }
              position="top"
            >
              <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 dark:bg-red-900/30 text-red-800 dark:text-red-300 cursor-help">
                Error
              </span>
            </Tooltip>
          );
        }
        
        if (host.is_empty === false) {
          return (
            <Tooltip
              content={
                <div className="space-y-1">
                  <div className="font-semibold">Keys Out of Sync</div>
                  <div className="text-xs">{host.total_items || 0} difference{(host.total_items || 0) !== 1 ? 's' : ''} found</div>
                  <div className="text-xs">Click to view details and sync</div>
                </div>
              }
              position="top"
            >
              <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 dark:bg-red-900/30 text-red-800 dark:text-red-300 cursor-help">
                Needs Sync
              </span>
            </Tooltip>
          );
        }
        
        if (host.is_empty === true) {
          return (
            <Tooltip
              content="All expected SSH keys are correctly configured on this host"
              position="top"
            >
              <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 dark:bg-green-900/30 text-green-800 dark:text-green-300 cursor-help">
                Synchronized
              </span>
            </Tooltip>
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
        if (host.disabled) return <span className="text-gray-400 dark:text-gray-500">N/A</span>;
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
  const getHostStatus = (host: DiffHost): 'synchronized' | 'needs-sync' | 'error' | 'loading' | 'disabled' => {
    if (host.disabled) return 'disabled';
    if (host.loading) return 'loading';
    if (host.error) return 'error';
    if (host.is_empty === false) return 'needs-sync';
    if (host.is_empty === true) return 'synchronized';
    return 'loading';
  };

  // Filter hosts based on status
  const filteredHosts = useMemo(() => {
    if (statusFilter === 'all') return hosts;
    if (statusFilter === 'active') return hosts.filter(host => !host.disabled);
    return hosts.filter(host => getHostStatus(host) === statusFilter);
  }, [hosts, statusFilter]);

  // Status filter options
  const statusFilterOptions = [
    { value: 'active', label: 'Active Hosts', count: hosts.filter(h => !h.disabled).length },
    { value: 'all', label: 'All Hosts', count: hosts.length },
    { value: 'synchronized', label: 'Synchronized', count: hosts.filter(h => getHostStatus(h) === 'synchronized').length },
    { value: 'needs-sync', label: 'Needs Sync', count: hosts.filter(h => getHostStatus(h) === 'needs-sync').length },
    { value: 'error', label: 'Error', count: hosts.filter(h => getHostStatus(h) === 'error').length },
    { value: 'loading', label: 'Loading', count: hosts.filter(h => getHostStatus(h) === 'loading').length },
    { value: 'disabled', label: 'Disabled', count: hosts.filter(h => getHostStatus(h) === 'disabled').length },
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
            emptyMessage={
              statusFilter === 'all' ? "No hosts found. Please check your host configuration." :
              statusFilter === 'active' ? "No active hosts found. Please check your host configuration or view disabled hosts." :
              `No hosts with status '${statusFilterOptions.find(o => o.value === statusFilter)?.label || statusFilter}'.`
            }
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
        title={
          <div className="flex items-center justify-between w-full">
            <span>Host Details: {selectedHost?.name || ''}</span>
            {hostDetails && hostDetails.logins.length > 0 && (
              <Button
                onClick={() => setShowSyncModal(true)}
                leftIcon={<Upload size={16} />}
                variant="primary"
                className="bg-blue-600 hover:bg-blue-700 font-medium px-4 py-2"
                size="sm"
              >
                Sync Keys
              </Button>
            )}
          </div>
        }
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
            {/* Host Information and Status Summary */}
            <div className="grid grid-cols-2 gap-6">
              {/* Basic Host Information */}
              <div className="bg-white dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700 p-4">
                <h3 className="text-lg font-semibold text-gray-900 dark:text-gray-100 mb-3 border-b border-gray-200 dark:border-gray-700 pb-2">Host Information</h3>
                <div className="grid grid-cols-2 gap-x-6 gap-y-3">
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

              {/* Status Summary */}
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
            </div>

            {/* Expected Keys */}
            {hostDetails.expected_keys.length > 0 && (
              <div className="bg-white dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700 p-4">
                <h3 className="text-lg font-semibold text-gray-900 dark:text-gray-100 mb-3 border-b border-gray-200 dark:border-gray-700 pb-2">Expected Keys</h3>
                <div className="max-h-64 overflow-y-auto">
                  <div className="grid grid-cols-3 gap-3">
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
                <div className="max-h-96 overflow-y-auto">
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
                                <DiffIssue issue={issue} onAllowKey={handleAllowKey} onAddUnknownKey={handleAddUnknownKey} />
                              </div>
                            </div>
                          ))}
                        </div>
                      </div>
                    </div>
                  ))}
                  </div>
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

      {/* Unknown Key Assignment Modal */}
      <Modal
        isOpen={showUnknownKeyModal}
        onClose={() => {
          setShowUnknownKeyModal(false);
          setUnknownKeyIssue(null);
        }}
        title="Add Unknown Key"
        size="md"
      >
        {unknownKeyIssue && (
          <div className="space-y-4">
            <div className="bg-gray-50 dark:bg-gray-800 p-4 rounded-lg">
              <h4 className="font-medium text-gray-900 dark:text-gray-100 mb-2">Key Details</h4>
              <div className="text-sm text-gray-700 dark:text-gray-300 space-y-1">
                <div><strong className="text-gray-900 dark:text-gray-100">Type:</strong> {unknownKeyIssue.details?.key?.key_type}</div>
                {unknownKeyIssue.details?.key?.comment && (
                  <div><strong className="text-gray-900 dark:text-gray-100">Comment:</strong> {unknownKeyIssue.details.key.comment}</div>
                )}
                <div><strong className="text-gray-900 dark:text-gray-100">Key (truncated):</strong> {unknownKeyIssue.details?.key?.base64.substring(0, 32)}...</div>
              </div>
            </div>

            <div className="space-y-3">
              <h4 className="font-medium text-gray-900 dark:text-gray-100">Choose an option:</h4>
              
              {/* Assign to existing user */}
              <div className="space-y-2">
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
                  Assign to existing user:
                </label>
                <select
                  className="w-full h-10 px-3 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
                  onChange={(e) => {
                    if (e.target.value) {
                      handleAssignToExistingUser(Number(e.target.value));
                    }
                  }}
                  defaultValue=""
                >
                  <option value="">Select a user...</option>
                  {allUsers.length === 0 ? (
                    <option disabled>No users found</option>
                  ) : (
                    allUsers.filter(u => u.enabled).map(user => (
                      <option key={user.id} value={user.id}>
                        {user.username}
                      </option>
                    ))
                  )}
                </select>
              </div>

              {/* Create new user */}
              <div className="pt-3 border-t border-gray-200 dark:border-gray-700">
                <div className="flex items-center justify-between">
                  <div>
                    <p className="text-sm font-medium text-gray-700 dark:text-gray-300">
                      Create new user
                    </p>
                    {unknownKeyIssue.details?.key?.comment ? (
                      <div className="space-y-1">
                        <p className="text-xs text-gray-500 dark:text-gray-400">
                          Username: <code className="bg-gray-100 dark:bg-gray-700 px-1 rounded">
                            {unknownKeyIssue.details.key.comment.trim()}
                          </code>
                        </p>
                        {(() => {
                          const username = unknownKeyIssue.details.key.comment.trim();
                          const existingUser = allUsers.find(u => u.username.toLowerCase() === username.toLowerCase());
                          const isValid = username.length >= 2 && /^[a-zA-Z0-9._-]+$/.test(username);
                          
                          if (existingUser) {
                            return <p className="text-xs text-amber-500">⚠ User already exists</p>;
                          } else if (!isValid) {
                            return <p className="text-xs text-red-500">⚠ Invalid username format</p>;
                          }
                          return null;
                        })()}
                      </div>
                    ) : (
                      <p className="text-xs text-red-500">
                        Key has no comment - cannot create user
                      </p>
                    )}
                  </div>
                  <Button
                    onClick={handleCreateNewUser}
                    disabled={(() => {
                      if (!unknownKeyIssue.details?.key?.comment) return true;
                      const username = unknownKeyIssue.details.key.comment.trim();
                      const existingUser = allUsers.find(u => u.username.toLowerCase() === username.toLowerCase());
                      const isValid = username.length >= 2 && /^[a-zA-Z0-9._-]+$/.test(username);
                      return !!existingUser || !isValid;
                    })()}
                    size="sm"
                  >
                    Create User
                  </Button>
                </div>
              </div>
            </div>
          </div>
        )}
      </Modal>

      {/* Sync Modal */}
      <SyncModal
        isOpen={showSyncModal}
        onClose={() => setShowSyncModal(false)}
        hostDetails={hostDetails}
        onSync={handleSyncKeys}
      />

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