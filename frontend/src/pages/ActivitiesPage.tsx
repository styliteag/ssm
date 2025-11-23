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
    const [expandedDiff, setExpandedDiff] = useState<number | null>(null);

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

    // Helper to render detailed diff
    const renderDetailedDiff = (diff: any[]) => {
        return (
            <div className="mt-2 border border-border rounded-md p-3 bg-muted/30 space-y-3">
                {diff.map((loginDiff: any, idx: number) => (
                    <div key={idx} className="space-y-1">
                        <div className="text-xs font-semibold text-foreground">Login: {loginDiff.login}</div>
                        <div className="space-y-1 pl-2">
                            {loginDiff.changes.map((change: any, changeIdx: number) => {
                                const actionColor = change.action === 'added' ? 'text-green-600 dark:text-green-400' :
                                    change.action === 'removed' ? 'text-red-600 dark:text-red-400' :
                                        'text-blue-600 dark:text-blue-400';
                                const actionSymbol = change.action === 'added' ? '+' :
                                    change.action === 'removed' ? '-' : '~';

                                return (
                                    <div key={changeIdx} className={`text-xs font-mono ${actionColor} flex gap-1`}>
                                        <span className="shrink-0">{actionSymbol}</span>
                                        <div className="flex-1">
                                            {change.username && <span className="font-semibold">{change.username}: </span>}
                                            <span>{change.key_type || 'key'}</span>
                                            {change.key_preview && <span className="opacity-70"> {change.key_preview}</span>}
                                            {change.comment && <span className="text-muted-foreground"> ({change.comment})</span>}
                                            {change.type === 'incorrect_options' && (
                                                <div className="text-xs mt-0.5 text-muted-foreground">
                                                    Options: <span className="line-through">{change.old_options}</span> → {change.new_options}
                                                </div>
                                            )}
                                            {change.error && (
                                                <div className="text-xs mt-0.5 text-muted-foreground">
                                                    Error: {change.error}
                                                </div>
                                            )}
                                        </div>
                                    </div>
                                );
                            })}
                        </div>
                    </div>
                ))}
            </div>
        );
    };

    // Helper to render metadata changes
    const renderChanges = (metadata?: Record<string, any>, activityId?: number) => {
        if (!metadata) return null;

        // Check if this is a changes metadata (has old/new structure)
        const changes = Object.entries(metadata).filter(([_key, value]) =>
            value && typeof value === 'object' && 'old' in value && 'new' in value
        );

        // Check if this is sync metadata (has counts like missing_keys, unknown_keys, etc.)
        const syncFields = ['missing_keys', 'unknown_keys', 'incorrect_options', 'faulty_keys',
            'unauthorized_keys', 'duplicate_keys', 'logins_affected'];
        const isSyncMetadata = syncFields.some(field => field in metadata);
        const hasDiff = metadata.diff && Array.isArray(metadata.diff) && metadata.diff.length > 0;

        if (changes.length === 0 && !isSyncMetadata && !hasDiff) return null;

        return (
            <div className="space-y-2">
                <div className="flex flex-wrap gap-2 mt-1">
                    {/* Render old/new changes */}
                    {changes.map(([field, change]: [string, any]) => (
                        <span key={field} className="text-xs bg-muted px-2 py-0.5 rounded">
                            <span className="text-muted-foreground">{field}:</span>{' '}
                            <span className="text-destructive line-through">{String(change.old ?? 'null')}</span>
                            {' → '}
                            <span className="text-green-600 dark:text-green-400">{String(change.new ?? 'null')}</span>
                        </span>
                    ))}

                    {/* Render sync summary */}
                    {isSyncMetadata && (
                        <>
                            {metadata.missing_keys > 0 && (
                                <span className="text-xs bg-red-100 dark:bg-red-900/20 text-red-700 dark:text-red-400 px-2 py-0.5 rounded">
                                    +{metadata.missing_keys} missing
                                </span>
                            )}
                            {metadata.unknown_keys > 0 && (
                                <span className="text-xs bg-amber-100 dark:bg-amber-900/20 text-amber-700 dark:text-amber-400 px-2 py-0.5 rounded">
                                    -{metadata.unknown_keys} unknown
                                </span>
                            )}
                            {metadata.incorrect_options > 0 && (
                                <span className="text-xs bg-blue-100 dark:bg-blue-900/20 text-blue-700 dark:text-blue-400 px-2 py-0.5 rounded">
                                    ⚙️ {metadata.incorrect_options} options fixed
                                </span>
                            )}
                            {metadata.unauthorized_keys > 0 && (
                                <span className="text-xs bg-orange-100 dark:bg-orange-900/20 text-orange-700 dark:text-orange-400 px-2 py-0.5 rounded">
                                    🚫 {metadata.unauthorized_keys} unauthorized
                                </span>
                            )}
                            {metadata.duplicate_keys > 0 && (
                                <span className="text-xs bg-purple-100 dark:bg-purple-900/20 text-purple-700 dark:text-purple-400 px-2 py-0.5 rounded">
                                    2x {metadata.duplicate_keys} duplicates
                                </span>
                            )}
                            {metadata.faulty_keys > 0 && (
                                <span className="text-xs bg-red-100 dark:bg-red-900/20 text-red-700 dark:text-red-400 px-2 py-0.5 rounded">
                                    ⚠️ {metadata.faulty_keys} faulty
                                </span>
                            )}
                            {metadata.logins_affected > 0 && (
                                <span className="text-xs bg-muted px-2 py-0.5 rounded text-muted-foreground">
                                    {metadata.logins_affected} login{metadata.logins_affected !== 1 ? 's' : ''} affected
                                </span>
                            )}
                        </>
                    )}
                    {hasDiff && activityId !== undefined && (
                        <button
                            onClick={() => setExpandedDiff(expandedDiff === activityId ? null : activityId)}
                            className="text-xs bg-primary/10 text-primary hover:bg-primary/20 px-2 py-0.5 rounded transition-colors"
                        >
                            {expandedDiff === activityId ? 'Hide Details' : 'View Details'}
                        </button>
                    )}
                </div>

                {/* Render detailed diff if expanded */}
                {hasDiff && expandedDiff === activityId && renderDetailedDiff(metadata.diff)}
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
                                            {renderChanges(activity.metadata, activity.id)}
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
