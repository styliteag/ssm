import React, { useState, useEffect, useCallback } from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import { Shield, Plus, Grid3X3, List, BarChart3, RefreshCw, FileDown, Settings } from 'lucide-react';
import { Button, Loading } from '../components/ui';
import { 
  Authorization, 
  AuthorizationWithDetails, 
  AuthorizationFormData, 
  User, 
  Host 
} from '../types';
import { authorizationsService } from '../services/api/authorizations';
import { usersService } from '../services/api/users';
import { hostsService } from '../services/api/hosts';
import AuthorizationMatrix from '../components/AuthorizationMatrix';
import AuthorizationList from '../components/AuthorizationList';
import AuthorizationStats from '../components/AuthorizationStats';
import {
  AddAuthorizationModal,
  EditAuthorizationModal,
  BulkGrantModal,
  DeleteAuthorizationModal
} from '../components/AuthorizationForms';

type ViewMode = 'stats' | 'matrix' | 'list';

const AuthorizationsPage: React.FC = () => {
  const location = useLocation();
  const navigate = useNavigate();
  
  // Check URL for view parameter and restore Matrix state
  const urlParams = new URLSearchParams(location.search);
  const urlView = urlParams.get('view') as ViewMode;
  
  // State management
  const [viewMode, setViewMode] = useState<ViewMode>(urlView || 'stats');
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  
  // Data state
  const [authorizations, setAuthorizations] = useState<Authorization[]>([]);
  const [authorizationsWithDetails, setAuthorizationsWithDetails] = useState<AuthorizationWithDetails[]>([]);
  const [users, setUsers] = useState<User[]>([]);
  const [hosts, setHosts] = useState<Host[]>([]);
  
  // Modal state
  const [showAddModal, setShowAddModal] = useState(false);
  const [showEditModal, setShowEditModal] = useState(false);
  const [showBulkModal, setShowBulkModal] = useState(false);
  const [showDeleteModal, setShowDeleteModal] = useState(false);
  const [selectedAuthorization, setSelectedAuthorization] = useState<Authorization | null>(null);

  // Handle view mode changes and update URL
  const handleViewModeChange = useCallback((newViewMode: ViewMode) => {
    setViewMode(newViewMode);
    
    // Update URL without triggering navigation
    const newUrl = newViewMode === 'stats' 
      ? '/authorizations' 
      : `/authorizations?view=${newViewMode}`;
    window.history.replaceState(null, '', newUrl);
  }, []);

  // Restore view state when component mounts
  useEffect(() => {
    if (urlView === 'matrix') {
      // Try to restore Matrix state from localStorage
      const savedState = localStorage.getItem('matrixNavigationState');
      if (savedState) {
        // Matrix component will handle this when it mounts
        console.log('Matrix state available for restoration');
      }
    } else if (urlView === 'stats') {
      // Try to restore Stats state from localStorage  
      const savedState = localStorage.getItem('statsNavigationState');
      if (savedState) {
        // Stats component will handle this when it mounts
        console.log('Stats state available for restoration');
      }
    }
  }, [urlView]);

  // Load all data
  const loadData = useCallback(async (showLoader = true) => {
    if (showLoader) setLoading(true);
    else setRefreshing(true);
    
    try {
      const [authResponse, usersResponse, hostsResponse] = await Promise.all([
        authorizationsService.getAuthorizations({ per_page: 1000 }),
        usersService.getAllUsers(),
        hostsService.getAllHosts(),
      ]);

      if (authResponse.success && authResponse.data) {
        setAuthorizations(authResponse.data.items);
      }
      
      if (usersResponse.success && usersResponse.data) {
        setUsers(usersResponse.data);
      }
      
      if (hostsResponse.success && hostsResponse.data) {
        setHosts(hostsResponse.data);
      }
    } catch (error) {
      console.error('Failed to load data:', error);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, []);

  // Create authorizations with details for list view
  useEffect(() => {
    console.log('Creating authorizationsWithDetails...');
    console.log('Authorizations count:', authorizations.length);
    console.log('Users count:', users.length);
    console.log('Hosts count:', hosts.length);
    
    if (authorizations.length > 0) {
      console.log('Sample authorization:', authorizations[0]);
    }
    if (users.length > 0) {
      console.log('Sample user:', users[0]);
    }
    if (hosts.length > 0) {
      console.log('Sample host:', hosts[0]);
    }
    
    const withDetails = authorizations.map(auth => {
      const user = users.find(u => u.id === auth.user_id);
      const host = hosts.find(h => h.id === auth.host_id);
      
      if (!user) {
        console.log(`No user found for user_id: ${auth.user_id}`);
      }
      if (!host) {
        console.log(`No host found for host_id: ${auth.host_id}`);
      }
      
      return {
        ...auth,
        user: user!,
        host: host!,
      };
    });
    setAuthorizationsWithDetails(withDetails);
  }, [authorizations, users, hosts]);

  // Load data on mount
  useEffect(() => {
    loadData();
  }, [loadData]);

  // Handle authorization toggle (for matrix view)
  const handleToggleAuthorization = useCallback(async (userId: number, hostId: number, isAuthorized: boolean) => {
    try {
      if (isAuthorized) {
        // Revoke access - find and delete the authorization
        const authorization = authorizations.find(auth => 
          auth.user_id === userId && auth.host_id === hostId
        );
        if (authorization) {
          await authorizationsService.deleteAuthorization(authorization.id);
          setAuthorizations(prev => prev.filter(auth => auth.id !== authorization.id));
        }
      } else {
        // Grant access - create new authorization
        const user = users.find(u => u.id === userId);
        const host = hosts.find(h => h.id === hostId);
        
        if (user && host) {
          const authData: AuthorizationFormData = {
            user_id: userId,
            host_id: hostId,
            login: host.username, // Default to host username
          };
          
          const response = await authorizationsService.createAuthorization(authData);
          if (response.success && response.data) {
            setAuthorizations(prev => [...prev, response.data!]);
          }
        }
      }
    } catch (error) {
      console.error('Failed to toggle authorization:', error);
      throw error; // Re-throw to let the matrix component handle the error
    }
  }, [authorizations, users, hosts]);

  // Handle add authorization
  const handleAddAuthorization = useCallback(async (data: AuthorizationFormData) => {
    const response = await authorizationsService.createAuthorization(data);
    if (response.success && response.data) {
      setAuthorizations(prev => [...prev, response.data!]);
    }
  }, []);

  // Handle edit authorization
  const handleEditAuthorization = useCallback(async (id: number, data: Partial<AuthorizationFormData>) => {
    const response = await authorizationsService.updateAuthorization(id, data);
    if (response.success && response.data) {
      setAuthorizations(prev => 
        prev.map(auth => auth.id === id ? response.data! : auth)
      );
    }
  }, []);

  // Handle delete authorization
  const handleDeleteAuthorization = useCallback(async (authorization: Authorization) => {
    setSelectedAuthorization(authorization);
    setShowDeleteModal(true);
  }, []);

  const confirmDeleteAuthorization = useCallback(async () => {
    if (!selectedAuthorization) return;
    
    await authorizationsService.deleteAuthorization(selectedAuthorization.id);
    setAuthorizations(prev => prev.filter(auth => auth.id !== selectedAuthorization.id));
  }, [selectedAuthorization]);

  // Handle bulk operations
  const handleBulkGrant = useCallback(async (authorizationsData: AuthorizationFormData[]) => {
    const response = await authorizationsService.createBulkAuthorizations(authorizationsData);
    if (response.success) {
      // Reload data to get the latest authorizations
      await loadData(false);
    }
  }, [loadData]);

  // Handle edit modal
  const handleEditClick = useCallback((authorization: Authorization) => {
    setSelectedAuthorization(authorization);
    setShowEditModal(true);
  }, []);

  // Handle test access (placeholder)
  const handleTestAccess = useCallback(async (authorization: Authorization) => {
    console.log('Testing access for:', authorization);
    // TODO: Implement SSH connection test
  }, []);

  // Export functionality
  const handleExport = useCallback(() => {
    const csvContent = [
      ['User', 'Host', 'Login Account', 'SSH Options', 'User Enabled', 'Host Address'].join(','),
      ...authorizationsWithDetails.map(auth => [
        auth.user?.username || '',
        auth.host?.name || '',
        auth.login,
        auth.options || '',
        auth.user?.enabled ? 'Yes' : 'No',
        auth.host?.address || ''
      ].map(field => `"${field}"`).join(','))
    ].join('\n');
    
    const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
    const link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = `authorizations-${new Date().toISOString().split('T')[0]}.csv`;
    link.click();
  }, [authorizationsWithDetails]);

  if (loading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loading text="Loading authorization data..." />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div>
        <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4 mb-4">
          <div>
            <h1 className="text-2xl font-bold text-gray-900 dark:text-white flex items-center space-x-2">
              <Shield size={24} />
              <span>Authorizations</span>
            </h1>
            <p className="text-gray-600 dark:text-gray-400">
              Manage user access permissions for hosts
            </p>
          </div>
        </div>
        
        {/* Action buttons in separate row */}
        <div className="flex flex-wrap items-center gap-3">
          {/* View Mode Toggle */}
          <div className="inline-flex bg-gray-100 dark:bg-gray-800 rounded-lg p-1">
            <Button
              size="sm"
              variant={viewMode === 'stats' ? 'primary' : 'ghost'}
              onClick={() => handleViewModeChange('stats')}
              leftIcon={<BarChart3 size={16} />}
              className="h-8"
            >
              Stats
            </Button>
            <Button
              size="sm"
              variant={viewMode === 'list' ? 'primary' : 'ghost'}
              onClick={() => handleViewModeChange('list')}
              leftIcon={<List size={16} />}
              className="h-8"
            >
              List
            </Button>
            <Button
              size="sm"
              variant={viewMode === 'matrix' ? 'primary' : 'ghost'}
              onClick={() => handleViewModeChange('matrix')}
              leftIcon={<Grid3X3 size={16} />}
              className="h-8"
            >
              Matrix
            </Button>
          </div>
          
          {/* Action Buttons */}
          <Button
            size="sm"
            variant="ghost"
            onClick={() => loadData(false)}
            loading={refreshing}
            leftIcon={<RefreshCw size={16} />}
          >
            Refresh
          </Button>
          
          <Button
            size="sm"
            variant="ghost"
            onClick={handleExport}
            leftIcon={<FileDown size={16} />}
          >
            Export
          </Button>
          
          <Button
            size="sm"
            variant="secondary"
            onClick={() => setShowBulkModal(true)}
            leftIcon={<Settings size={16} />}
          >
            Bulk Grant
          </Button>
          
          <Button
            size="sm"
            onClick={() => setShowAddModal(true)}
            leftIcon={<Plus size={16} />}
          >
            Grant Access
          </Button>
        </div>
      </div>

      {/* Content based on view mode */}
      {viewMode === 'stats' && (
        <AuthorizationStats
          authorizations={authorizations}
          users={users}
          hosts={hosts}
        />
      )}
      
      {viewMode === 'matrix' && (
        <AuthorizationMatrix
          users={users}
          hosts={hosts}
          authorizations={authorizations}
          onToggleAuthorization={handleToggleAuthorization}
          loading={refreshing}
          onViewModeChange={handleViewModeChange}
        />
      )}
      
      {viewMode === 'list' && (
        <AuthorizationList
          authorizations={authorizationsWithDetails}
          users={users}
          hosts={hosts}
          onEdit={handleEditClick}
          onDelete={handleDeleteAuthorization}
          onTestAccess={handleTestAccess}
          loading={refreshing}
        />
      )}

      {/* Modals */}
      <AddAuthorizationModal
        isOpen={showAddModal}
        onClose={() => setShowAddModal(false)}
        onSubmit={handleAddAuthorization}
        users={users}
        hosts={hosts}
        existingAuthorizations={authorizations}
      />
      
      <EditAuthorizationModal
        isOpen={showEditModal}
        onClose={() => {
          setShowEditModal(false);
          setSelectedAuthorization(null);
        }}
        onSubmit={handleEditAuthorization}
        authorization={selectedAuthorization}
        users={users}
        hosts={hosts}
      />
      
      <BulkGrantModal
        isOpen={showBulkModal}
        onClose={() => setShowBulkModal(false)}
        onSubmit={handleBulkGrant}
        users={users}
        hosts={hosts}
        existingAuthorizations={authorizations}
      />
      
      <DeleteAuthorizationModal
        isOpen={showDeleteModal}
        onClose={() => {
          setShowDeleteModal(false);
          setSelectedAuthorization(null);
        }}
        onConfirm={confirmDeleteAuthorization}
        authorization={selectedAuthorization}
        user={selectedAuthorization ? users.find(u => u.id === selectedAuthorization.user_id) : undefined}
        host={selectedAuthorization ? hosts.find(h => h.id === selectedAuthorization.host_id) : undefined}
      />
    </div>
  );
};

export default AuthorizationsPage;