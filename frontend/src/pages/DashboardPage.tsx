import React, { useState, useEffect } from 'react';
import { Link } from 'react-router-dom';
import { Server, Users, Key, Shield, Activity, AlertCircle } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle, Loading } from '../components/ui';
import { hostsService, usersService, keysService, authorizationsService } from '../services/api';

interface DashboardStats {
  hosts: number;
  users: number;
  keys: number;
  authorizations: number;
}

const DashboardPage: React.FC = () => {
  const [stats, setStats] = useState<DashboardStats>({
    hosts: 0,
    users: 0,
    keys: 0,
    authorizations: 0,
  });
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    loadDashboardData();
  }, []);

  const loadDashboardData = async () => {
    try {
      setIsLoading(true);
      setError(null);

      // Load basic counts for dashboard
      const [hostsResponse, usersResponse, keysResponse, authResponse] = await Promise.allSettled([
        hostsService.getAllHosts(),
        usersService.getAllUsers(),
        keysService.getKeys({ per_page: 1 }),
        authorizationsService.getAuthorizations({ per_page: 1 }),
      ]);

      const newStats: DashboardStats = {
        hosts: hostsResponse.status === 'fulfilled' ? hostsResponse.value.data?.length || 0 : 0,
        users: usersResponse.status === 'fulfilled' ? usersResponse.value.data?.length || 0 : 0,
        keys: keysResponse.status === 'fulfilled' ? keysResponse.value.data?.total || 0 : 0,
        authorizations: authResponse.status === 'fulfilled' ? authResponse.value.data?.total || 0 : 0,
      };

      setStats(newStats);
    } catch (err: any) {
      setError('Failed to load dashboard data');
      console.error('Dashboard load error:', err);
    } finally {
      setIsLoading(false);
    }
  };

  const statCards = [
    {
      title: 'Hosts',
      value: stats.hosts,
      icon: Server,
      color: 'bg-blue-500',
      link: '/hosts',
      description: 'Total managed hosts',
    },
    {
      title: 'Users',
      value: stats.users,
      icon: Users,
      color: 'bg-green-500',
      link: '/users',
      description: 'Active users',
    },
    {
      title: 'SSH Keys',
      value: stats.keys,
      icon: Key,
      color: 'bg-purple-500',
      link: '/keys',
      description: 'Total SSH keys',
    },
    {
      title: 'Authorizations',
      value: stats.authorizations,
      icon: Shield,
      color: 'bg-orange-500',
      link: '/authorizations',
      description: 'Active authorizations',
    },
  ];

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-64">
        <Loading size="lg" text="Loading dashboard..." />
      </div>
    );
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div>
        <h1 className="text-2xl font-bold text-gray-900 dark:text-white">
          Dashboard
        </h1>
        <p className="text-gray-600 dark:text-gray-400">
          Welcome to SSH Key Manager - Overview of your infrastructure
        </p>
      </div>

      {/* Error Alert */}
      {error && (
        <Card variant="bordered" className="border-red-200 dark:border-red-800">
          <CardContent className="pt-6">
            <div className="flex items-center space-x-2 text-red-600 dark:text-red-400">
              <AlertCircle size={20} />
              <span>{error}</span>
            </div>
          </CardContent>
        </Card>
      )}

      {/* Stats Grid */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
        {statCards.map((card) => (
          <Link key={card.title} to={card.link}>
            <Card className="hover:shadow-lg transition-shadow cursor-pointer">
              <CardContent className="p-6">
                <div className="flex items-center justify-between">
                  <div>
                    <p className="text-sm font-medium text-gray-600 dark:text-gray-400">
                      {card.title}
                    </p>
                    <p className="text-3xl font-bold text-gray-900 dark:text-white">
                      {card.value}
                    </p>
                    <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                      {card.description}
                    </p>
                  </div>
                  <div className={`p-3 rounded-full ${card.color}`}>
                    <card.icon size={24} className="text-white" />
                  </div>
                </div>
              </CardContent>
            </Card>
          </Link>
        ))}
      </div>

      {/* Quick Actions */}
      <Card>
        <CardHeader>
          <CardTitle>Quick Actions</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
            <Link
              to="/hosts"
              className="flex items-center space-x-3 p-4 bg-gray-50 dark:bg-gray-800 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
            >
              <Server size={20} className="text-blue-600 dark:text-blue-400" />
              <span className="font-medium text-gray-900 dark:text-white">
                Manage Hosts
              </span>
            </Link>
            
            <Link
              to="/users"
              className="flex items-center space-x-3 p-4 bg-gray-50 dark:bg-gray-800 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
            >
              <Users size={20} className="text-green-600 dark:text-green-400" />
              <span className="font-medium text-gray-900 dark:text-white">
                Manage Users
              </span>
            </Link>
            
            <Link
              to="/keys"
              className="flex items-center space-x-3 p-4 bg-gray-50 dark:bg-gray-800 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
            >
              <Key size={20} className="text-purple-600 dark:text-purple-400" />
              <span className="font-medium text-gray-900 dark:text-white">
                SSH Keys
              </span>
            </Link>
            
            <Link
              to="/authorizations"
              className="flex items-center space-x-3 p-4 bg-gray-50 dark:bg-gray-800 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
            >
              <Shield size={20} className="text-orange-600 dark:text-orange-400" />
              <span className="font-medium text-gray-900 dark:text-white">
                Authorizations
              </span>
            </Link>
          </div>
        </CardContent>
      </Card>

      {/* System Status */}
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center space-x-2">
            <Activity size={20} />
            <span>System Status</span>
          </CardTitle>
        </CardHeader>
        <CardContent>
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <span className="text-sm font-medium text-gray-600 dark:text-gray-400">
                API Connection
              </span>
              <span className="flex items-center space-x-2 text-sm text-green-600 dark:text-green-400">
                <div className="w-2 h-2 bg-green-500 rounded-full"></div>
                <span>Connected</span>
              </span>
            </div>
            
            <div className="flex items-center justify-between">
              <span className="text-sm font-medium text-gray-600 dark:text-gray-400">
                Authentication
              </span>
              <span className="flex items-center space-x-2 text-sm text-green-600 dark:text-green-400">
                <div className="w-2 h-2 bg-green-500 rounded-full"></div>
                <span>Active</span>
              </span>
            </div>
          </div>
        </CardContent>
      </Card>
    </div>
  );
};

export default DashboardPage;