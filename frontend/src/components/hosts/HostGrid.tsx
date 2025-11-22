import React from 'react';
import { Host } from '../../types';
import { HostCard } from './HostCard';

interface HostGridProps {
    hosts: Host[];
    onEdit: (host: Host) => void;
    onDelete: (host: Host) => void;
    onConnect: (host: Host) => void;
}

export const HostGrid: React.FC<HostGridProps> = ({ hosts, onEdit, onDelete, onConnect }) => {
    if (hosts.length === 0) {
        return (
            <div className="text-center py-12 text-muted-foreground">
                No hosts found. Add one to get started.
            </div>
        );
    }

    return (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6 animate-in fade-in duration-500">
            {hosts.map((host) => (
                <HostCard
                    key={host.id}
                    host={host}
                    onEdit={onEdit}
                    onDelete={onDelete}
                    onConnect={onConnect}
                />
            ))}
        </div>
    );
};
