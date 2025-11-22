import React, { useState, useEffect } from 'react';
import { Link } from 'react-router-dom';
import { Server, Users, Key, Shield, Activity, AlertCircle, ArrowRight } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle, Loading } from '../components/ui';
import { StatCard } from '../components/dashboard/StatCard';
import { DashboardChart } from '../components/dashboard/DashboardCharts';
import { ActivityFeed } from '../components/dashboard/ActivityFeed';
import { hostsService, usersService, keysService, authorizationsService, systemService } from '../services/api';

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
  const [version, setVersion] = useState<string>('');
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    loadDashboardData();
  }, []);

  const loadDashboardData = async () => {
    try {
      setIsLoading(true);
      setError(null);

      const [hostsResponse, usersResponse, keysResponse, authResponse, systemResponse] = await Promise.allSettled([
        hostsService.getAllHosts(),
        usersService.getAllUsers(),
        keysService.getKeys({ per_page: 1 }),
        authorizationsService.getAuthorizations({ per_page: 1 }),
        systemService.getApiInfo(),
      ]);

      const newStats: DashboardStats = {
        hosts: hostsResponse.status === 'fulfilled' ? hostsResponse.value.data?.length || 0 : 0,
        users: usersResponse.status === 'fulfilled' ? usersResponse.value.data?.length || 0 : 0,
        keys: keysResponse.status === 'fulfilled' ? keysResponse.value.data?.total || 0 : 0,
        authorizations: authResponse.status === 'fulfilled' ? authResponse.value.data?.total || 0 : 0,
      };

      setStats(newStats);

      if (systemResponse.status === 'fulfilled') {
        setVersion(systemResponse.value.data?.version || '');
      }
    } catch (err: unknown) {
      setError('Failed to load dashboard data');
      console.error('Dashboard load error:', err);
    } finally {
      setIsLoading(false);
    }
  };

  const pieData = [
    { name: 'Active', value: stats.hosts },
    { name: 'Disabled', value: 2 }, // Mock disabled count
  ];

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-[calc(100vh-4rem)]">
        <Loading size="lg" text="Loading dashboard..." />
      </div>
    );
  }

  return (
    <div className="space-y-8 animate-in fade-in duration-500">
      {/* Header */}
      <div className="flex flex-col md:flex-row justify-between items-start md:items-center gap-4">
        <div>
          <h1 className="text-3xl font-bold tracking-tight text-foreground">
            Dashboard
          </h1>
          <p className="text-muted-foreground mt-1">
            Overview of your infrastructure and security status
          </p>
        </div>
        <div className="flex items-center space-x-2 bg-card border border-border px-3 py-1.5 rounded-full shadow-sm">
          <div className="w-2 h-2 bg-green-500 rounded-full animate-pulse"></div>
          <span className="text-sm font-medium text-muted-foreground">System Operational</span>
          {version && <span className="text-xs text-muted-foreground/60 border-l border-border pl-2 ml-2">v{version}</span>}
        </div>
      </div>

      {/* Error Alert */}
      {error && (
        <div className="bg-destructive/10 border border-destructive/20 text-destructive px-4 py-3 rounded-lg flex items-center space-x-2">
          <AlertCircle size={20} />
          <span>{error}</span>
        </div>
      )}

      {/* Stats Grid */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-6">
        <Link to="/hosts">
          <StatCard
            title="Total Hosts"
            value={stats.hosts}
            icon={Server}
            iconColor="text-blue-500"
            trend={{ value: 12, isPositive: true }}
            gradient="bg-gradient-to-br from-blue-500 to-blue-600"
          />
        </Link>
        <Link to="/users">
          <StatCard
            title="Active Users"
            value={stats.users}
            icon={Users}
            iconColor="text-green-500"
            trend={{ value: 5, isPositive: true }}
            gradient="bg-gradient-to-br from-green-500 to-green-600"
          />
        </Link>
        <Link to="/keys">
          <StatCard
            title="SSH Keys"
            value={stats.keys}
            icon={Key}
            iconColor="text-purple-500"
            trend={{ value: 2, isPositive: true }}
            gradient="bg-gradient-to-br from-purple-500 to-purple-600"
          />
        </Link>
        <Link to="/authorizations">
          <StatCard
            title="Authorizations"
            value={stats.authorizations}
            icon={Shield}
            iconColor="text-orange-500"
            trend={{ value: 0, isPositive: true }}
            gradient="bg-gradient-to-br from-orange-500 to-orange-600"
          />
        </Link>
      </div>

      {/* Main Content Grid */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Left Column */}
        <div className="lg:col-span-2 space-y-6">
          {/* Quick Actions */}
          <Card>
            <CardHeader>
              <CardTitle className="text-base font-medium">Quick Actions</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <Link
                  to="/hosts"
                  className="group flex items-center justify-between p-4 bg-secondary/50 hover:bg-secondary rounded-lg transition-colors border border-transparent hover:border-border"
                >
                  <div className="flex items-center space-x-3">
                    <div className="p-2 bg-blue-100 dark:bg-blue-900/30 rounded-md text-blue-600 dark:text-blue-400">
                      <Server size={20} />
                    </div>
                    <span className="font-medium">Add New Host</span>
                  </div>
                  <ArrowRight size={16} className="text-muted-foreground group-hover:translate-x-1 transition-transform" />
                </Link>

                <Link
                  to="/users"
                  className="group flex items-center justify-between p-4 bg-secondary/50 hover:bg-secondary rounded-lg transition-colors border border-transparent hover:border-border"
                >
                  <div className="flex items-center space-x-3">
                    <div className="p-2 bg-green-100 dark:bg-green-900/30 rounded-md text-green-600 dark:text-green-400">
                      <Users size={20} />
                    </div>
                    <span className="font-medium">Add New User</span>
                  </div>
                  <ArrowRight size={16} className="text-muted-foreground group-hover:translate-x-1 transition-transform" />
                </Link>

                <Link
                  to="/keys"
                  className="group flex items-center justify-between p-4 bg-secondary/50 hover:bg-secondary rounded-lg transition-colors border border-transparent hover:border-border"
                >
                  <div className="flex items-center space-x-3">
                    <div className="p-2 bg-purple-100 dark:bg-purple-900/30 rounded-md text-purple-600 dark:text-purple-400">
                      <Key size={20} />
                    </div>
                    <span className="font-medium">Manage Keys</span>
                  </div>
                  <ArrowRight size={16} className="text-muted-foreground group-hover:translate-x-1 transition-transform" />
                </Link>

                <Link
                  to="/diff"
                  className="group flex items-center justify-between p-4 bg-secondary/50 hover:bg-secondary rounded-lg transition-colors border border-transparent hover:border-border"
                >
                  <div className="flex items-center space-x-3">
                    <div className="p-2 bg-orange-100 dark:bg-orange-900/30 rounded-md text-orange-600 dark:text-orange-400">
                      <Activity size={20} />
                    </div>
                    <span className="font-medium">View Changes</span>
                  </div>
                  <ArrowRight size={16} className="text-muted-foreground group-hover:translate-x-1 transition-transform" />
                </Link>
              </div>
            </CardContent>
          </Card>

          {/* System Status & Health */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            <DashboardChart
              type="pie"
              title="Host Status"
              data={pieData}
              dataKey="value"
              height={200}
            />
            <Card className="flex flex-col justify-center p-6 bg-gradient-to-br from-primary/5 to-primary/10 border-primary/20 h-full">
              <div className="text-center space-y-2">
                <h3 className="text-lg font-semibold text-primary">System Health</h3>
                <p className="text-4xl font-bold text-foreground">98.5%</p>
                <p className="text-sm text-muted-foreground">Uptime this month</p>
                <div className="w-full bg-secondary h-2 rounded-full mt-4 overflow-hidden">
                  <div className="bg-green-500 h-full rounded-full" style={{ width: '98.5%' }}></div>
                </div>
              </div>
            </Card>
          </div>
        </div>

        {/* Right Column - Activity Feed */}
        <div className="lg:col-span-1 h-full">
          <ActivityFeed />
        </div>
      </div>
    </div>
  );
};

export default DashboardPage;