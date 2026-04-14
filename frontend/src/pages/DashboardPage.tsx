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
 <h1 className="text-[32px] leading-tight font-w510 tracking-h1 text-foreground">
 Dashboard
 </h1>
 <p className="text-muted-foreground mt-2 tracking-body-lg">
 Overview of your infrastructure and security status
 </p>
 </div>
 <div className="flex items-center space-x-2 bg-white/[0.03] border border-border px-3 py-1 rounded-full">
 <div className="w-1.5 h-1.5 bg-success rounded-full animate-pulse"></div>
 <span className="text-xs font-w510 text-muted-foreground">System Operational</span>
 {version && <span className="text-xs text-muted-foreground/60 border-l border-border pl-2 ml-1 font-mono">v{version}</span>}
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
 <Link to="/hosts" className="cursor-pointer">
 <StatCard
 title="Total Hosts"
 value={stats.hosts}
 icon={Server}
 iconColor="text-primary"
 gradient="bg-primary"
 />
 </Link>
 <Link to="/users" className="cursor-pointer">
 <StatCard
 title="Active Users"
 value={stats.users}
 icon={Users}
 iconColor="text-success"
 gradient="bg-success"
 />
 </Link>
 <Link to="/keys" className="cursor-pointer">
 <StatCard
 title="SSH Keys"
 value={stats.keys}
 icon={Key}
 iconColor="text-accent"
 gradient="bg-accent"
 />
 </Link>
 <Link to="/authorizations" className="cursor-pointer">
 <StatCard
 title="Authorizations"
 value={stats.authorizations}
 icon={Shield}
 iconColor="text-warning"
 gradient="bg-warning"
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
 <CardTitle>Quick Actions</CardTitle>
 </CardHeader>
 <CardContent>
 <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
 <Link
 to="/hosts"
 className="group flex items-center justify-between p-4 bg-white/[0.02] hover:bg-white/[0.05] rounded-lg transition-colors border border-border cursor-pointer"
 >
 <div className="flex items-center space-x-3">
 <div className="p-2 bg-primary/15 rounded-md text-primary border border-primary/25">
 <Server size={20} />
 </div>
 <span className="font-w510">Add New Host</span>
 </div>
 <ArrowRight size={16} className="text-muted-foreground group-hover:translate-x-1 transition-transform" />
 </Link>

 <Link
 to="/users"
 className="group flex items-center justify-between p-4 bg-white/[0.02] hover:bg-white/[0.05] rounded-lg transition-colors border border-border cursor-pointer"
 >
 <div className="flex items-center space-x-3">
 <div className="p-2 bg-success/15 rounded-md text-success border border-success/25">
 <Users size={20} />
 </div>
 <span className="font-w510">Add New User</span>
 </div>
 <ArrowRight size={16} className="text-muted-foreground group-hover:translate-x-1 transition-transform" />
 </Link>

 <Link
 to="/keys"
 className="group flex items-center justify-between p-4 bg-white/[0.02] hover:bg-white/[0.05] rounded-lg transition-colors border border-border cursor-pointer"
 >
 <div className="flex items-center space-x-3">
 <div className="p-2 bg-accent/15 rounded-md text-accent border border-accent/25">
 <Key size={20} />
 </div>
 <span className="font-w510">Manage Keys</span>
 </div>
 <ArrowRight size={16} className="text-muted-foreground group-hover:translate-x-1 transition-transform" />
 </Link>

 <Link
 to="/diff"
 className="group flex items-center justify-between p-4 bg-white/[0.02] hover:bg-white/[0.05] rounded-lg transition-colors border border-border cursor-pointer"
 >
 <div className="flex items-center space-x-3">
 <div className="p-2 bg-warning/15 rounded-md text-warning border border-warning/25">
 <Activity size={20} />
 </div>
 <span className="font-w510">View Changes</span>
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
 <Card className="flex flex-col justify-center p-6 h-full">
 <div className="text-center space-y-2">
 <h3 className="text-xs font-w510 text-muted-foreground uppercase tracking-wider">Summary</h3>
 <p className="text-[48px] leading-[1] font-w510 tracking-display text-foreground">{stats.hosts + stats.users}</p>
 <p className="text-sm text-muted-foreground tracking-body-lg">Total managed resources</p>
 <div className="mt-4 grid grid-cols-2 gap-3 text-sm">
 <div className="text-muted-foreground">{stats.keys} keys</div>
 <div className="text-muted-foreground">{stats.authorizations} auths</div>
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