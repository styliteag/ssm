import React, { useState, useMemo } from 'react';
import { Edit, Trash2, TestTube, UserCheck, Shield, AlertTriangle } from 'lucide-react';
import { cn } from '../utils/cn';
import { Authorization, AuthorizationWithDetails, User, Host } from '../types';
import DataTable, { Column } from './ui/DataTable';
import Button from './ui/Button';

// Enhanced type that includes computed search fields
type EnhancedAuthorizationWithDetails = AuthorizationWithDetails & {
  user_name: string;
  host_name: string;
  host_address: string;
  host_search: string;
  status_text: string;
  login_search: string;
  combined_search: string;
  [key: string]: unknown;
};

interface AuthorizationListProps {
  authorizations: AuthorizationWithDetails[];
  users: User[];
  hosts: Host[];
  onEdit: (authorization: Authorization) => void;
  onDelete: (authorization: Authorization) => void;
  onTestAccess?: (authorization: Authorization) => void;
  loading?: boolean;
  className?: string;
}

const AuthorizationList: React.FC<AuthorizationListProps> = ({
  authorizations,
  onEdit,
  onDelete,
  onTestAccess,
  loading = false,
  className,
}) => {
  const [selectedAuthorizations, setSelectedAuthorizations] = useState<Set<number>>(new Set());

  // Create columns for the data table
  const columns: Column<EnhancedAuthorizationWithDetails>[] = useMemo(() => [
    {
      key: 'user_name',
      header: 'User',
      sortable: true,
      searchable: true,
      render: (_, auth) => (
        <div className="flex items-center space-x-2">
          <div className={cn(
            'w-2 h-2 rounded-full',
            auth.user?.enabled ? 'bg-green-500' : 'bg-red-500'
          )} />
          <span className={cn(
            'font-medium',
            !auth.user?.enabled && 'text-gray-500 line-through'
          )}>
            {auth.user?.username || 'Unknown User'}
          </span>
          {!auth.user?.enabled && (
            <span className="text-xs text-gray-400 bg-gray-100 dark:bg-gray-800 px-1 rounded">
              disabled
            </span>
          )}
        </div>
      ),
    },
    {
      key: 'host_search',
      header: 'Host',
      sortable: true,
      searchable: true,
      render: (_, auth) => (
        <div className="space-y-1">
          <div className="font-medium">{auth.host?.name || 'Unknown Host'}</div>
          <div className="text-sm text-gray-500">
            {auth.host?.address}
            {auth.host?.port && auth.host.port !== 22 && `:${auth.host.port}`}
          </div>
        </div>
      ),
    },
    {
      key: 'login',
      header: 'Login Account',
      sortable: true,
      searchable: true,
      render: (value) => (
        <span className="font-mono text-sm bg-gray-100 dark:bg-gray-800 px-2 py-1 rounded">
          {(value as string) || '-'}
        </span>
      ),
    },
    {
      key: 'options',
      header: 'SSH Options',
      sortable: false,
      searchable: true,
      render: (value) => (value as string) ? (
        <div className="max-w-xs">
          <div
            className="font-mono text-xs bg-gray-100 dark:bg-gray-800 p-2 rounded truncate"
            title={value as string}
          >
            {value as string}
          </div>
        </div>
      ) : (
        <span className="text-gray-400">None</span>
      ),
    },
    {
      key: 'comment',
      header: 'Comment',
      sortable: true,
      searchable: true,
      render: (value) => (
        <div className="max-w-xs">
          {(value as string) ? (
            <div
              className="text-sm bg-gray-100 dark:bg-gray-800 p-2 rounded truncate"
              title={value as string}
            >
              {value as string}
            </div>
          ) : (
            <span className="text-gray-400 italic">No comment</span>
          )}
        </div>
      ),
    },
    {
      key: 'id',
      header: 'Status',
      sortable: true,
      searchable: true,
      render: (_, auth) => {
        const userEnabled = auth.user?.enabled ?? true;
        const hasValidUser = !!auth.user;
        const hasValidHost = !!auth.host;
        
        if (!hasValidUser || !hasValidHost) {
          return (
            <div className="flex items-center space-x-2">
              <AlertTriangle size={16} className="text-red-500" />
              <span className="text-red-600 text-sm">Invalid</span>
            </div>
          );
        }
        
        if (!userEnabled) {
          return (
            <div className="flex items-center space-x-2">
              <Shield size={16} className="text-yellow-500" />
              <span className="text-yellow-600 text-sm">User Disabled</span>
            </div>
          );
        }
        
        return (
          <div className="flex items-center space-x-2">
            <UserCheck size={16} className="text-green-500" />
            <span className="text-green-600 text-sm">Active</span>
          </div>
        );
      },
    },
    {
      key: 'actions',
      header: 'Actions',
      sortable: false,
      width: '140px',
      render: (_, auth) => (
        <div className="flex items-center space-x-1">
          <Button
            size="sm"
            variant="ghost"
            onClick={() => onEdit(auth)}
            leftIcon={<Edit size={14} />}
            className="h-8 w-8 p-0"
            title="Edit authorization"
          />
          {onTestAccess && (
            <Button
              size="sm"
              variant="ghost"
              onClick={() => onTestAccess(auth)}
              leftIcon={<TestTube size={14} />}
              className="h-8 w-8 p-0"
              title="Test SSH access"
            />
          )}
          <Button
            size="sm"
            variant="ghost"
            onClick={() => onDelete(auth)}
            leftIcon={<Trash2 size={14} />}
            className="h-8 w-8 p-0 text-red-600 hover:text-red-700 hover:bg-red-50 dark:hover:bg-red-900/20"
            title="Delete authorization"
          />
        </div>
      ),
    },
  ], [onEdit, onDelete, onTestAccess]);

  // Handle row selection
  const handleRowClick = (auth: EnhancedAuthorizationWithDetails) => {
    setSelectedAuthorizations(prev => {
      const newSet = new Set(prev);
      if (newSet.has(auth.id)) {
        newSet.delete(auth.id);
      } else {
        newSet.add(auth.id);
      }
      return newSet;
    });
  };

  // Enhanced data with computed fields for better searching and sorting
  const enhancedData = useMemo((): EnhancedAuthorizationWithDetails[] => {
    return authorizations.map(auth => ({
      ...auth,
      user_name: auth.user?.username || '',
      host_name: auth.host?.name || '',
      host_address: auth.host?.address || '',
      host_search: `${auth.host?.name || ''} ${auth.host?.address || ''}`.trim(),
      status_text: auth.user?.enabled ? 'Active' : 'Disabled',
      // Make login searchable as a string
      login_search: auth.login || '',
      // Combined search field for comprehensive searching
      combined_search: `${auth.user?.username || ''} ${auth.host?.name || ''} ${auth.host?.address || ''} ${auth.login || ''} ${auth.comment || ''} ${auth.user?.enabled ? 'Active' : 'Disabled'}`.toLowerCase(),
    }));
  }, [authorizations]);

  // Statistics for the data
  const stats = useMemo(() => {
    const totalAuthorizations = authorizations.length;
    const activeAuthorizations = authorizations.filter(auth => auth.user?.enabled).length;
    const uniqueUsers = new Set(authorizations.map(auth => auth.user_id)).size;
    const uniqueHosts = new Set(authorizations.map(auth => auth.host_id)).size;
    
    return {
      total: totalAuthorizations,
      active: activeAuthorizations,
      inactive: totalAuthorizations - activeAuthorizations,
      users: uniqueUsers,
      hosts: uniqueHosts,
    };
  }, [authorizations]);

  return (
    <div className={cn('space-y-4', className)}>
      {/* Statistics Header */}
      <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
        <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border border-gray-200 dark:border-gray-700">
          <div className="text-sm font-medium text-gray-500 dark:text-gray-400">Total</div>
          <div className="text-2xl font-bold text-gray-900 dark:text-white">{stats.total}</div>
        </div>
        <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border border-gray-200 dark:border-gray-700">
          <div className="text-sm font-medium text-gray-500 dark:text-gray-400">Active</div>
          <div className="text-2xl font-bold text-green-600">{stats.active}</div>
        </div>
        <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border border-gray-200 dark:border-gray-700">
          <div className="text-sm font-medium text-gray-500 dark:text-gray-400">Inactive</div>
          <div className="text-2xl font-bold text-yellow-600">{stats.inactive}</div>
        </div>
        <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border border-gray-200 dark:border-gray-700">
          <div className="text-sm font-medium text-gray-500 dark:text-gray-400">Users</div>
          <div className="text-2xl font-bold text-blue-600">{stats.users}</div>
        </div>
        <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border border-gray-200 dark:border-gray-700">
          <div className="text-sm font-medium text-gray-500 dark:text-gray-400">Hosts</div>
          <div className="text-2xl font-bold text-purple-600">{stats.hosts}</div>
        </div>
      </div>

      {/* Bulk Actions */}
      {selectedAuthorizations.size > 0 && (
        <div className="bg-blue-50 dark:bg-blue-900/20 p-4 rounded-lg border border-blue-200 dark:border-blue-800">
          <div className="flex items-center justify-between">
            <span className="text-sm font-medium text-blue-900 dark:text-blue-100">
              {selectedAuthorizations.size} authorization(s) selected
            </span>
            <div className="flex items-center space-x-2">
              <Button
                size="sm"
                variant="secondary"
                onClick={() => {
                  // Handle bulk delete
                  const selectedAuths = authorizations.filter(auth => 
                    selectedAuthorizations.has(auth.id)
                  );
                  selectedAuths.forEach(auth => onDelete(auth));
                  setSelectedAuthorizations(new Set());
                }}
                leftIcon={<Trash2 size={14} />}
                className="text-red-600 hover:text-red-700"
              >
                Delete Selected
              </Button>
              <Button
                size="sm"
                variant="ghost"
                onClick={() => setSelectedAuthorizations(new Set())}
              >
                Clear Selection
              </Button>
            </div>
          </div>
        </div>
      )}

      {/* Data Table */}
      <DataTable
        data={enhancedData}
        columns={columns}
        loading={loading}
        searchable={true}
        sortable={true}
        paginated={true}
        pageSize={20}
        onRowClick={handleRowClick}
        emptyMessage="No authorizations found. Create some authorizations to get started."
        searchPlaceholder="Search users, hosts, or login accounts..."
        className="bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700"
        stickyHeader={true}
        initialSort={{ key: 'user_name', direction: 'asc' }}
      />
    </div>
  );
};

export default AuthorizationList;