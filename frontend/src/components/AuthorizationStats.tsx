import React, { useState, useMemo } from 'react';
import { Users, Server, Shield, UserCheck, AlertTriangle, TrendingUp, Search } from 'lucide-react';
import { Authorization, User, Host } from '../types';
import { Card, CardContent, CardHeader, CardTitle } from './ui';
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
  const [searchTerm, setSearchTerm] = useState('');
  
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
    
    const activeUsers = filteredUsers.filter(user => user.enabled);
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
                    <div className="flex items-center space-x-3">
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
                        <div className="font-medium text-gray-900 dark:text-white">
                          {item.host.name}
                        </div>
                        <div className="text-sm text-gray-500 dark:text-gray-400">
                          {item.host.address}
                        </div>
                      </div>
                    </div>
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
                    <div className="flex items-center space-x-3">
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
                        <div className={cn(
                          'font-medium',
                          !item.user.enabled && 'text-gray-500 line-through'
                        )}>
                          {item.user.username}
                        </div>
                        {!item.user.enabled && (
                          <span className="text-xs text-gray-400 bg-gray-100 dark:bg-gray-700 px-1 rounded">
                            disabled
                          </span>
                        )}
                      </div>
                    </div>
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
    </div>
  );
};

export default AuthorizationStats;