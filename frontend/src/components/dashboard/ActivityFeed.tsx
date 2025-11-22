import React from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '../ui/Card';
import { Key, Server, User, Shield } from 'lucide-react';

interface ActivityItem {
    id: string;
    type: 'key' | 'host' | 'user' | 'auth';
    action: string;
    target: string;
    user: string;
    timestamp: string;
}

// Mock data for now
const mockActivities: ActivityItem[] = [
    { id: '1', type: 'key', action: 'Added new key', target: 'id_rsa_prod', user: 'admin', timestamp: '2 mins ago' },
    { id: '2', type: 'host', action: 'Updated host', target: 'web-server-01', user: 'admin', timestamp: '15 mins ago' },
    { id: '3', type: 'auth', action: 'Granted access', target: 'dev-team -> db-01', user: 'system', timestamp: '1 hour ago' },
    { id: '4', type: 'user', action: 'Created user', target: 'jdoe', user: 'admin', timestamp: '3 hours ago' },
    { id: '5', type: 'key', action: 'Rotated key', target: 'deploy_key', user: 'admin', timestamp: '5 hours ago' },
];

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
    return (
        <Card className="h-full">
            <CardHeader>
                <CardTitle className="text-base font-medium">Recent Activity</CardTitle>
            </CardHeader>
            <CardContent>
                <div className="space-y-6">
                    {mockActivities.map((activity) => {
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
            </CardContent>
        </Card>
    );
};
