import React from 'react';
import { Server, Globe, User, Edit2, Trash2, Terminal } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle, Button } from '../ui';
import { cn } from '../../utils/cn';
import { Host } from '../../types';

interface HostCardProps {
    host: Host;
    onEdit: (host: Host) => void;
    onDelete: (host: Host) => void;
    onConnect: (host: Host) => void;
}

export const HostCard: React.FC<HostCardProps> = ({ host, onEdit, onDelete, onConnect }) => {
    const statusColors = {
        online: 'bg-green-500',
        offline: 'bg-red-500',
        error: 'bg-orange-500',
        unknown: 'bg-gray-400',
        disabled: 'bg-gray-300'
    };

    const status = host.disabled ? 'disabled' : (host.connection_status as keyof typeof statusColors) || 'unknown';

    return (
        <Card className="group hover:shadow-lg transition-all duration-300 border-border/50 bg-card/50 backdrop-blur-sm">
            <CardHeader className="flex flex-row items-start justify-between space-y-0 pb-2">
                <div className="flex items-center space-x-3">
                    <div className={cn("p-2 rounded-lg bg-primary/10 text-primary group-hover:bg-primary group-hover:text-primary-foreground transition-colors duration-300")}>
                        <Server size={20} />
                    </div>
                    <div>
                        <CardTitle className="text-base font-semibold">{host.name}</CardTitle>
                        <div className="flex items-center text-xs text-muted-foreground mt-1">
                            <span className={cn("w-2 h-2 rounded-full mr-2", statusColors[status])} />
                            <span className="capitalize">{status}</span>
                        </div>
                    </div>
                </div>
                <div className="flex space-x-2 opacity-0 group-hover:opacity-100 transition-opacity duration-200">
                    <Button variant="ghost" size="sm" className="h-10 w-10 p-0" onClick={() => onEdit(host)}>
                        <Edit2 size={20} />
                    </Button>
                    <Button variant="ghost" size="sm" className="h-10 w-10 p-0 text-destructive hover:text-destructive" onClick={() => onDelete(host)}>
                        <Trash2 size={20} />
                    </Button>
                </div>
            </CardHeader>
            <CardContent>
                <div className="space-y-3 text-sm">
                    <div className="flex items-center text-muted-foreground">
                        <Globe size={14} className="mr-2" />
                        <span className="truncate">{host.address}:{host.port}</span>
                    </div>
                    <div className="flex items-center text-muted-foreground">
                        <User size={14} className="mr-2" />
                        <span className="truncate">{host.username}</span>
                    </div>

                    <div className="pt-4">
                        <Button
                            variant="outline"
                            className="w-full justify-center group-hover:border-primary/50 group-hover:text-primary transition-colors"
                            onClick={() => onConnect(host)}
                            disabled={host.disabled}
                        >
                            <Terminal size={14} className="mr-2" />
                            Test Connection
                        </Button>
                    </div>
                </div>
            </CardContent>
        </Card>
    );
};
