import React, { useEffect, useState } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '../ui/Card';
import { Key, Server, User, Shield, Loader2, AlertCircle } from 'lucide-react';
import { activitiesService, Activity } from '../../services/api/activities';

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

export const ActivityFeed: React.FC = () => {
    const [activities, setActivities] = useState<Activity[]>([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState<string | null>(null);

    useEffect(() => {
        const fetchActivities = async () => {
            setLoading(true);
            setError(null);
            const response = await activitiesService.getActivities(10);

            if (response.success && response.data) {
                setActivities(response.data);
            } else {
                setError(response.message || 'Failed to load activities');
            }
            setLoading(false);
        };

        fetchActivities();

        // Refresh activities every 30 seconds
        const interval = setInterval(fetchActivities, 30000);
        return () => clearInterval(interval);
    }, []);

    return (
        <Card className="h-full">
            <CardHeader>
                <CardTitle className="text-base font-medium">Recent Activity</CardTitle>
            </CardHeader>
            <CardContent>
                {loading ? (
                    <div className="flex items-center justify-center py-8">
                        <Loader2 size={24} className="animate-spin text-primary" />
                    </div>
                ) : error ? (
                    <div className="flex items-center gap-2 py-8 text-destructive">
                        <AlertCircle size={20} />
                        <span className="text-sm">{error}</span>
                    </div>
                ) : activities.length === 0 ? (
                    <div className="py-8 text-center text-muted-foreground text-sm">
                        No recent activity
                    </div>
                ) : (
                    <div className="space-y-6">
                        {activities.map((activity) => {
                            const Icon = iconMap[activity.type];
                            return (
                                <div key={activity.id} className="flex items-start space-x-4">
                                    <div className={`p-2 rounded-full ${colorMap[activity.type]}`}>
                                        <Icon size={16} />
                                    </div>
                                    <div className="flex-1 space-y-1">
                                        <p className="text-sm font-medium text-foreground">
                                            {activity.action} <span className="text-muted-foreground">on</span> {activity.target}
                                        </p>
                                        <div className="flex items-center text-xs text-muted-foreground">
                                            <span>{activity.user}</span>
                                            <span className="mx-1">•</span>
                                            <span>{activity.timestamp}</span>
                                        </div>
                                    </div>
                                </div>
                            );
                        })}
                    </div>
                )}
            </CardContent>
        </Card>
    );
};
