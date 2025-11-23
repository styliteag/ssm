import React, { useEffect, useState } from 'react';
import { Key, Server, User, Shield, Loader2, AlertCircle, Activity as ActivityIcon, Search } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '../components/ui/Card';
import { Input } from '../components/ui';
import { activitiesService, Activity } from '../services/api/activities';

const iconMap = {
    key: Key,
    host: Server,
    user: User,
    auth: Shield,
};

const colorMap = {
    key: 'text-purple-500 bg-purple-100 dark:bg-purple-900/20',
    host: 'text-blue-500 bg-blue-100 dark:bg-blue-900/20',
    user: 'text-green-500 bg-green-100 dark:bg-green-900/20',
    auth: 'text-orange-500 bg-orange-100 dark:bg-orange-900/20',
};

const ActivitiesPage: React.FC = () => {
    const [activities, setActivities] = useState<Activity[]>([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);
    const [searchQuery, setSearchQuery] = useState('');

    useEffect(() => {
        const fetchActivities = async () => {
            setLoading(true);
            setError(null);
            // Fetch more activities for the full page view
            const response = await activitiesService.getActivities(100);

            if (response.success && response.data) {
                setActivities(response.data);
            } else {
                setError(response.message || 'Failed to load activities');
            }
            setLoading(false);
        };

        fetchActivities();
    }, []);

    const filteredActivities = activities.filter(activity =>
        activity.action.toLowerCase().includes(searchQuery.toLowerCase()) ||
        activity.target.toLowerCase().includes(searchQuery.toLowerCase()) ||
        activity.user.toLowerCase().includes(searchQuery.toLowerCase())
    );

    // Helper to render metadata changes
    const renderChanges = (metadata?: Record<string, any>) => {
        if (!metadata) return null;

        // Check if this is a changes metadata (has old/new structure)
        const changes = Object.entries(metadata).filter(([_key, value]) =>
            value && typeof value === 'object' && 'old' in value && 'new' in value
        );

        if (changes.length === 0) return null;

        return (
            <div className="flex flex-wrap gap-2 mt-1">
                {changes.map(([field, change]: [string, any]) => (
                    <span key={field} className="text-xs bg-muted px-2 py-0.5 rounded">
                        <span className="text-muted-foreground">{field}:</span>{' '}
                        <span className="text-destructive line-through">{String(change.old ?? 'null')}</span>
                        {' → '}
                        <span className="text-green-600 dark:text-green-400">{String(change.new ?? 'null')}</span>
                    </span>
                ))}
            </div>
        );
    };

    return (
        <div className="space-y-6 animate-in fade-in duration-500">
            <div className="flex flex-col md:flex-row justify-between items-start md:items-center gap-4">
                <div>
                    <h1 className="text-3xl font-bold tracking-tight text-foreground">
                        Activity Log
                    </h1>
                    <p className="text-muted-foreground mt-1">
                        View recent system events and audit trail
                    </p>
                </div>
            </div>

            <Card>
                <CardHeader className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 space-y-0 pb-4">
                    <CardTitle className="flex items-center gap-2">
                        <ActivityIcon className="h-5 w-5" />
                        Recent Activities
                    </CardTitle>
                    <div className="relative w-full sm:w-64">
                        <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-muted-foreground" />
                        <Input
                            placeholder="Search activities..."
                            className="pl-9 h-9"
                            value={searchQuery}
                            onChange={(e) => setSearchQuery(e.target.value)}
                        />
                    </div>
                </CardHeader>
                <CardContent className="p-0">
                    {loading ? (
                        <div className="flex items-center justify-center py-12">
                            <Loader2 size={32} className="animate-spin text-primary" />
                        </div>
                    ) : error ? (
                        <div className="flex items-center gap-2 py-8 text-destructive justify-center">
                            <AlertCircle size={24} />
                            <span className="text-lg">{error}</span>
                        </div>
                    ) : filteredActivities.length === 0 ? (
                        <div className="py-12 text-center text-muted-foreground">
                            {activities.length === 0 ? "No activities found" : "No matching activities found"}
                        </div>
                    ) : (
                        <div className="divide-y divide-border">
                            {filteredActivities.map((activity) => {
                                const Icon = iconMap[activity.type] || ActivityIcon;
                                return (
                                    <div key={activity.id} className="flex items-start gap-3 p-2 px-4 hover:bg-muted/50 transition-colors">
                                        <div className={`p-1.5 rounded-full shrink-0 mt-0.5 ${colorMap[activity.type] || 'text-gray-500 bg-gray-100'}`}>
                                            <Icon size={16} />
                                        </div>
                                        <div className="flex-1 min-w-0">
                                            <div className="flex flex-col sm:flex-row sm:items-center gap-1 sm:gap-2">
                                                <div className="flex items-center gap-2 min-w-0">
                                                    <span className="font-medium text-sm text-foreground truncate">
                                                        {activity.action}
                                                    </span>
                                                    <span className="text-xs text-muted-foreground shrink-0">on</span>
                                                    <span className="font-medium text-sm text-foreground truncate">
                                                        {activity.target}
                                                    </span>
                                                </div>
                                            </div>
                                            {renderChanges(activity.metadata)}
                                        </div>
                                        <div className="flex items-center gap-4 shrink-0 text-xs text-muted-foreground">
                                            <div className="hidden sm:flex items-center gap-1">
                                                <User size={12} />
                                                <span>{activity.user}</span>
                                            </div>
                                            {activity.metadata?.ip && (
                                                <div className="hidden md:flex items-center gap-1 text-xs bg-muted px-1.5 py-0.5 rounded" title={activity.metadata.via ? `Via: ${activity.metadata.via}` : undefined}>
                                                    <span className="font-mono">{activity.metadata.ip}</span>
                                                </div>
                                            )}
                                            <span className="w-20 sm:w-24 text-right whitespace-nowrap">{activity.timestamp}</span>
                                        </div>
                                    </div>
                                );
                            })}
                        </div>
                    )}
                </CardContent>
            </Card>
        </div>
    );
};

export default ActivitiesPage;
