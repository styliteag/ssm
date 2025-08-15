import React, { useState, useMemo, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { Users, Server, Shield, UserCheck, AlertTriangle, TrendingUp, Search, Edit2 } from 'lucide-react';
import { Authorization, User, Host, HostFormData, UserFormData } from '../types';
import { Card, CardContent, CardHeader, CardTitle, Modal, Form, Button } from './ui';
import { useNotifications } from '../contexts/NotificationContext';
import { hostsService } from '../services/api/hosts';
import { usersService } from '../services/api/users';
import Input from './ui/Input';
import { cn } from '../utils/cn';

interface AuthorizationStatsProps {
  authorizations: Authorization[];
  users: User[];
  hosts: Host[];
  className?: string;
}

interface StatItem {
  label: string;
  value: number;
  icon: React.ReactNode;
  color: string;
  description?: string;
  trend?: {
    value: number;
    isPositive: boolean;
  };
}

interface HostUserCount {
  host: Host;
  userCount: number;
  activeUserCount: number;
}

interface UserHostCount {
  user: User;
  hostCount: number;
}

const AuthorizationStats: React.FC<AuthorizationStatsProps> = ({
  authorizations,
  users,
  hosts,
  className,
}) => {
  const navigate = useNavigate();
  const { showSuccess, showError } = useNotifications();
  const [searchTerm, setSearchTerm] = useState('');
  
  // Edit modal states
  const [showEditHostModal, setShowEditHostModal] = useState(false);
  const [showEditUserModal, setShowEditUserModal] = useState(false);
  const [selectedHost, setSelectedHost] = useState<Host | null>(null);
  const [selectedUser, setSelectedUser] = useState<User | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // Restore state from localStorage if returning from navigation
  useEffect(() => {
    const savedState = localStorage.getItem('statsNavigationState');
    if (savedState) {
      try {
        const state = JSON.parse(savedState);
        setSearchTerm(state.searchTerm || '');
        
        // Clear the saved state after restoring
        localStorage.removeItem('statsNavigationState');
      } catch (error) {
        console.error('Error restoring stats state:', error);
        localStorage.removeItem('statsNavigationState');
      }
    }
  }, []);

  // Handle user click to navigate to Users page with search
  const handleUserClick = (username: string) => {
    // Save current state for back navigation
    const statsState = {
      searchTerm, // Current search term in stats
    };
    localStorage.setItem('statsNavigationState', JSON.stringify(statsState));
    navigate('/users', { state: { searchTerm: username } });
  };

  // Handle host click to navigate to Hosts page with search
  const handleHostClick = (hostname: string) => {
    // Save current state for back navigation  
    const statsState = {
      searchTerm, // Current search term in stats
    };
    localStorage.setItem('statsNavigationState', JSON.stringify(statsState));
    navigate('/hosts', { state: { searchTerm: hostname } });
  };

  // Handle edit host
  const handleEditHost = (host: Host) => {
    setSelectedHost(host);
    setShowEditHostModal(true);
  };

  // Handle edit user
  const handleEditUser = (user: User) => {
    setSelectedUser(user);
    setShowEditUserModal(true);
  };

  // Handle host form submission
  const handleHostFormSubmit = async (values: HostFormData) => {
    if (!selectedHost) return;

    try {
      setSubmitting(true);
      const response = await hostsService.updateHost(selectedHost.name, values);
      if (response.success && response.data) {
        setShowEditHostModal(false);
        setSelectedHost(null);
        showSuccess('Host updated', `${String(response.data.name)} has been updated successfully`);
      }
    } catch {
      showError('Failed to update host', 'Please check your input and try again');
    } finally {
      setSubmitting(false);
    }
  };

  // Handle user form submission
  const handleUserFormSubmit = async (values: UserFormData) => {
    if (!selectedUser) return;

    try {
      setSubmitting(true);
      const userData = {
        username: selectedUser.username, // Keep original username
        enabled: typeof values.enabled === 'string' ? values.enabled === 'true' : Boolean(values.enabled)
      };
      const response = await usersService.updateUser(selectedUser.username, userData);
      if (response.success && response.data) {
        setShowEditUserModal(false);
        setSelectedUser(null);
        showSuccess('User updated', `${String(response.data.username)} has been updated successfully`);
      }
    } catch {
      showError('Failed to update user', 'Please check your input and try again');
    } finally {
      setSubmitting(false);
    }
  };
  
  // Filter data based on search term
  const filteredData = useMemo(() => {
    let filteredUsers = users;
    let filteredHosts = hosts;
    let filteredAuthorizations = authorizations;
    
    if (searchTerm.trim()) {
      const searchLower = searchTerm.toLowerCase();
      
      // Filter users
      filteredUsers = users.filter(user => 
        user.username.toLowerCase().includes(searchLower)
      );
      
      // Filter hosts
      filteredHosts = hosts.filter(host => 
        host.name.toLowerCase().includes(searchLower) || 
        host.address.toLowerCase().includes(searchLower)
      );
      
      // Get IDs for filtered users and hosts
      const filteredUserIds = new Set(filteredUsers.map(u => u.id));
      const filteredHostIds = new Set(filteredHosts.map(h => h.id));
      
      // Filter authorizations to only include filtered users and hosts
      filteredAuthorizations = authorizations.filter(auth => 
        filteredUserIds.has(auth.user_id) || filteredHostIds.has(auth.host_id)
      );
    }
    
    return { 
      users: filteredUsers, 
      hosts: filteredHosts, 
      authorizations: filteredAuthorizations 
    };
  }, [users, hosts, authorizations, searchTerm]);
  
  // Calculate comprehensive statistics
  const stats = useMemo(() => {
    const { users: filteredUsers, hosts: filteredHosts, authorizations: filteredAuthorizations } = filteredData;
    
    const activeAuthorizations = filteredAuthorizations.filter(auth => {
      const user = filteredUsers.find(u => u.id === auth.user_id);
      return user?.enabled ?? true;
    });

    // Basic counts
    const totalAuthorizations = filteredAuthorizations.length;
    const activeAuthorizationsCount = activeAuthorizations.length;
    const inactiveAuthorizationsCount = totalAuthorizations - activeAuthorizationsCount;

    // User-related stats
    const usersWithAccess = new Set(filteredAuthorizations.map(auth => auth.user_id)).size;
    const activeUsersWithAccess = new Set(
      activeAuthorizations.map(auth => auth.user_id)
    ).size;

    // Host-related stats
    const hostsWithUsers = new Set(filteredAuthorizations.map(auth => auth.host_id)).size;
    const hostsWithActiveUsers = new Set(
      activeAuthorizations.map(auth => auth.host_id)
    ).size;

    // Coverage percentages
    const userCoverage = filteredUsers.length > 0 ? (usersWithAccess / filteredUsers.length) * 100 : 0;
    const hostCoverage = filteredHosts.length > 0 ? (hostsWithUsers / filteredHosts.length) * 100 : 0;

    // Top hosts by user count (using filtered data)
    const hostUserCounts: HostUserCount[] = filteredHosts.map(host => {
      const hostAuths = filteredAuthorizations.filter(auth => auth.host_id === host.id);
      const activeHostAuths = hostAuths.filter(auth => {
        const user = filteredUsers.find(u => u.id === auth.user_id);
        return user?.enabled ?? true;
      });
      
      return {
        host,
        userCount: hostAuths.length,
        activeUserCount: activeHostAuths.length,
      };
    }).sort((a, b) => b.activeUserCount - a.activeUserCount);

    // Top users by host count (using filtered data)
    const userHostCounts: UserHostCount[] = filteredUsers.map(user => {
      const userAuths = filteredAuthorizations.filter(auth => auth.user_id === user.id);
      return {
        user,
        hostCount: userAuths.length,
      };
    }).sort((a, b) => b.hostCount - a.hostCount);

    return {
      totalAuthorizations,
      activeAuthorizationsCount,
      inactiveAuthorizationsCount,
      usersWithAccess,
      activeUsersWithAccess,
      hostsWithUsers,
      hostsWithActiveUsers,
      userCoverage,
      hostCoverage,
      topHosts: hostUserCounts.slice(0, 5),
      topUsers: userHostCounts.slice(0, 5),
    };
  }, [filteredData]);

  // Create stat items for display
  const statItems: StatItem[] = [
    {
      label: 'Total Authorizations',
      value: stats.totalAuthorizations,
      icon: <Shield className="h-5 w-5" />,
      color: 'text-blue-600',
      description: 'All access permissions',
    },
    {
      label: 'Active Authorizations',
      value: stats.activeAuthorizationsCount,
      icon: <UserCheck className="h-5 w-5" />,
      color: 'text-green-600',
      description: 'For enabled users only',
    },
    {
      label: 'Inactive Authorizations',
      value: stats.inactiveAuthorizationsCount,
      icon: <AlertTriangle className="h-5 w-5" />,
      color: 'text-yellow-600',
      description: 'For disabled users',
    },
    {
      label: 'Users with Access',
      value: stats.activeUsersWithAccess,
      icon: <Users className="h-5 w-5" />,
      color: 'text-purple-600',
      description: `${stats.userCoverage.toFixed(1)}% of all users`,
    },
    {
      label: 'Hosts with Users',
      value: stats.hostsWithActiveUsers,
      icon: <Server className="h-5 w-5" />,
      color: 'text-indigo-600',
      description: `${stats.hostCoverage.toFixed(1)}% of all hosts`,
    },
    {
      label: 'Average Access per User',
      value: stats.activeUsersWithAccess > 0 
        ? Math.round(stats.activeAuthorizationsCount / stats.activeUsersWithAccess * 10) / 10 
        : 0,
      icon: <TrendingUp className="h-5 w-5" />,
      color: 'text-pink-600',
      description: 'Hosts per active user',
    },
  ];

  return (
    <div className={cn('space-y-6', className)}>
      {/* Search Input */}
      <div className="flex justify-center">
        <Input
          type="text"
          placeholder="Search users, hosts, or addresses..."
          value={searchTerm}
          onChange={(e) => setSearchTerm(e.target.value)}
          leftIcon={<Search size={16} />}
          className="max-w-md"
        />
      </div>
      
      {/* Main Statistics Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        {statItems.map((stat, index) => (
          <Card key={index} className="hover:shadow-md transition-shadow">
            <CardContent className="p-6">
              <div className="flex items-center justify-between">
                <div>
                  <p className="text-sm font-medium text-gray-600 dark:text-gray-400">
                    {stat.label}
                  </p>
                  <div className="flex items-baseline space-x-2">
                    <p className={cn('text-2xl font-semibold', stat.color)}>
                      {typeof stat.value === 'number' && stat.value % 1 !== 0 
                        ? stat.value.toFixed(1) 
                        : stat.value}
                    </p>
                    {stat.trend && (
                      <span className={cn(
                        'text-sm font-medium',
                        stat.trend.isPositive ? 'text-green-600' : 'text-red-600'
                      )}>
                        {stat.trend.isPositive ? '+' : '-'}{Math.abs(stat.trend.value)}%
                      </span>
                    )}
                  </div>
                  {stat.description && (
                    <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                      {stat.description}
                    </p>
                  )}
                </div>
                <div className={cn('p-3 rounded-full bg-gray-100 dark:bg-gray-800', stat.color)}>
                  {stat.icon}
                </div>
              </div>
            </CardContent>
          </Card>
        ))}
      </div>

      {/* Top Hosts and Users */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Top Hosts by User Count */}
        <Card>
          <CardHeader>
            <CardTitle className="text-lg">Hosts by User Access</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="space-y-3">
              {stats.topHosts.length > 0 ? (
                stats.topHosts.map((item, index) => (
                  <div
                    key={item.host.id}
                    className="flex items-center justify-between p-3 bg-gray-50 dark:bg-gray-800 rounded-lg"
                  >
                    <div className="flex items-center space-x-3 flex-1">
                      <div className={cn(
                        'flex items-center justify-center w-8 h-8 rounded-full text-sm font-medium',
                        index === 0 ? 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200' :
                        index === 1 ? 'bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-200' :
                        index === 2 ? 'bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200' :
                        'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200'
                      )}>
                        {index + 1}
                      </div>
                      <div>
                        <button
                          onClick={() => handleHostClick(item.host.name)}
                          className="font-medium text-left hover:text-blue-600 dark:hover:text-blue-400 transition-colors underline-offset-2 hover:underline text-gray-900 dark:text-white"
                        >
                          {item.host.name}
                        </button>
                        <div className="text-sm text-gray-500 dark:text-gray-400">
                          {item.host.address}
                        </div>
                      </div>
                    </div>
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={(e) => {
                        e.stopPropagation();
                        handleEditHost(item.host);
                      }}
                      className="h-10 w-10 p-1 text-gray-400 hover:text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/20"
                      title="Edit host"
                    >
                      <Edit2 size={20} />
                    </Button>
                    <div className="text-right">
                      <div className="font-semibold text-gray-900 dark:text-white">
                        {item.activeUserCount}
                      </div>
                      <div className="text-xs text-gray-500 dark:text-gray-400">
                        active users
                      </div>
                      {item.userCount !== item.activeUserCount && (
                        <div className="text-xs text-yellow-600 dark:text-yellow-400">
                          (+{item.userCount - item.activeUserCount} inactive)
                        </div>
                      )}
                    </div>
                  </div>
                ))
              ) : (
                <div className="text-center py-8 text-gray-500 dark:text-gray-400">
                  <Server className="h-12 w-12 mx-auto mb-3 opacity-50" />
                  <p>No hosts with user access</p>
                </div>
              )}
            </div>
          </CardContent>
        </Card>

        {/* Top Users by Host Count */}
        <Card>
          <CardHeader>
            <CardTitle className="text-lg">Users by Host Access</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="space-y-3">
              {stats.topUsers.length > 0 ? (
                stats.topUsers.filter(item => item.hostCount > 0).map((item, index) => (
                  <div
                    key={item.user.id}
                    className="flex items-center justify-between p-3 bg-gray-50 dark:bg-gray-800 rounded-lg"
                  >
                    <div className="flex items-center space-x-3 flex-1">
                      <div className={cn(
                        'flex items-center justify-center w-8 h-8 rounded-full text-sm font-medium',
                        index === 0 ? 'bg-yellow-100 text-yellow-800 dark:bg-yellow-900 dark:text-yellow-200' :
                        index === 1 ? 'bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-200' :
                        index === 2 ? 'bg-orange-100 text-orange-800 dark:bg-orange-900 dark:text-orange-200' :
                        'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200'
                      )}>
                        {index + 1}
                      </div>
                      <div className="flex items-center space-x-2">
                        <div className={cn(
                          'w-2 h-2 rounded-full',
                          item.user.enabled ? 'bg-green-500' : 'bg-red-500'
                        )} />
                        <button
                          onClick={() => handleUserClick(item.user.username)}
                          className={cn(
                            'font-medium text-left hover:text-blue-600 dark:hover:text-blue-400 transition-colors underline-offset-2 hover:underline text-gray-900 dark:text-white',
                            !item.user.enabled && 'text-gray-500 line-through hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-300'
                          )}
                        >
                          {item.user.username}
                        </button>
                        {!item.user.enabled && (
                          <span className="text-xs text-gray-400 bg-gray-100 dark:bg-gray-700 px-1 rounded">
                            disabled
                          </span>
                        )}
                      </div>
                    </div>
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={(e) => {
                        e.stopPropagation();
                        handleEditUser(item.user);
                      }}
                      className="h-10 w-10 p-1 text-gray-400 hover:text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/20"
                      title="Edit user"
                    >
                      <Edit2 size={20} />
                    </Button>
                    <div className="text-right">
                      <div className="font-semibold text-gray-900 dark:text-white">
                        {item.hostCount}
                      </div>
                      <div className="text-xs text-gray-500 dark:text-gray-400">
                        hosts
                      </div>
                    </div>
                  </div>
                ))
              ) : (
                <div className="text-center py-8 text-gray-500 dark:text-gray-400">
                  <Users className="h-12 w-12 mx-auto mb-3 opacity-50" />
                  <p>No users with host access</p>
                </div>
              )}
            </div>
          </CardContent>
        </Card>
      </div>

      {/* Coverage Indicators */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <Card>
          <CardHeader>
            <CardTitle className="text-lg">User Coverage</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="space-y-3">
              <div className="flex justify-between text-sm">
                <span>Users with access</span>
                <span>{stats.activeUsersWithAccess} / {users.filter(u => u.enabled).length}</span>
              </div>
              <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2">
                <div 
                  className="bg-purple-600 h-2 rounded-full transition-all duration-300"
                  style={{ width: `${Math.min(stats.userCoverage, 100)}%` }}
                />
              </div>
              <div className="text-xs text-gray-500 dark:text-gray-400">
                {stats.userCoverage.toFixed(1)}% of enabled users have access to at least one host
              </div>
            </div>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-lg">Host Coverage</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="space-y-3">
              <div className="flex justify-between text-sm">
                <span>Hosts with users</span>
                <span>{stats.hostsWithActiveUsers} / {hosts.length}</span>
              </div>
              <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2">
                <div 
                  className="bg-indigo-600 h-2 rounded-full transition-all duration-300"
                  style={{ width: `${Math.min(stats.hostCoverage, 100)}%` }}
                />
              </div>
              <div className="text-xs text-gray-500 dark:text-gray-400">
                {stats.hostCoverage.toFixed(1)}% of hosts have at least one active user
              </div>
            </div>
          </CardContent>
        </Card>
      </div>

      {/* Edit Host Modal */}
      <Modal
        isOpen={showEditHostModal}
        onClose={() => {
          setShowEditHostModal(false);
          setSelectedHost(null);
        }}
        title="Edit Host"
        size="lg"
      >
        {selectedHost && (
          <Form
            fields={[
              {
                name: 'name',
                label: 'Host Name',
                type: 'text',
                required: true,
                placeholder: 'Enter host name',
                helperText: 'Friendly name for this host',
                validation: {
                  minLength: 2,
                  maxLength: 100
                }
              },
              {
                name: 'address',
                label: 'Address',
                type: 'text',
                required: true,
                placeholder: 'hostname.example.com or IP address',
                helperText: 'IP address or hostname to connect to',
                validation: {
                  minLength: 3,
                  maxLength: 255
                }
              },
              {
                name: 'port',
                label: 'SSH Port',
                type: 'number',
                required: true,
                placeholder: '22',
                helperText: 'SSH port number (usually 22)',
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
                placeholder: 'root, ubuntu, etc.',
                helperText: 'Username for SSH connection',
                validation: {
                  minLength: 1,
                  maxLength: 50
                }
              }
            ]}
            onSubmit={(values: Record<string, unknown>) => handleHostFormSubmit(values as unknown as HostFormData)}
            submitText="Save Changes"
            cancelText="Cancel"
            onCancel={() => {
              setShowEditHostModal(false);
              setSelectedHost(null);
            }}
            loading={submitting}
            layout="grid"
            gridCols={2}
            initialValues={{
              name: selectedHost.name,
              address: selectedHost.address,
              port: selectedHost.port,
              username: selectedHost.username
            }}
          />
        )}
      </Modal>

      {/* Edit User Modal */}
      <Modal
        isOpen={showEditUserModal}
        onClose={() => {
          setShowEditUserModal(false);
          setSelectedUser(null);
        }}
        title="Edit User"
        size="md"
      >
        {selectedUser && (
          <Form
            fields={[
              {
                name: 'username',
                label: 'Username',
                type: 'text',
                required: true,
                placeholder: 'Enter username',
                helperText: 'Unique username for SSH access',
                disabled: true, // Username cannot be changed after creation
                validation: {
                  minLength: 2,
                  maxLength: 50
                }
              },
              {
                name: 'enabled',
                label: 'User Status',
                type: 'select',
                required: true,
                placeholder: 'Select user status',
                helperText: 'Whether the user account is active',
                options: [
                  { value: 'true', label: 'Enabled (Active)' },
                  { value: 'false', label: 'Disabled (Inactive)' }
                ]
              }
            ]}
            onSubmit={(values: Record<string, unknown>) => handleUserFormSubmit(values as unknown as UserFormData)}
            submitText="Save Changes"
            cancelText="Cancel"
            onCancel={() => {
              setShowEditUserModal(false);
              setSelectedUser(null);
            }}
            loading={submitting}
            initialValues={{
              username: selectedUser.username,
              enabled: selectedUser.enabled.toString()
            }}
          />
        )}
      </Modal>
    </div>
  );
};

export default AuthorizationStats;