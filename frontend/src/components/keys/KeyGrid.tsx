import React from 'react';
import { PublicUserKey } from '../../types';
import { KeyCard } from './KeyCard';

interface ExtendedKey extends PublicUserKey {
    username?: string;
    fingerprint?: string;
    status: 'deployed' | 'pending' | 'error' | 'unknown';
    lastUsed?: Date;
    createdAt?: Date;
    hostCount?: number;
    [key: string]: unknown;
}

interface KeyGridProps {
    keys: ExtendedKey[];
    onEdit: (key: ExtendedKey) => void;
    onDelete: (key: ExtendedKey) => void;
    onAssign: (key: ExtendedKey) => void;
}

export const KeyGrid: React.FC<KeyGridProps> = ({
    keys,
    onEdit,
    onDelete,
    onAssign
}) => {
    if (keys.length === 0) {
        return (
            <div className="text-center py-12 text-muted-foreground">
                No SSH keys found. Add one to get started.
            </div>
        );
    }

    return (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6 animate-in fade-in duration-500">
            {keys.map((key) => (
                <KeyCard
                    key={key.id}
                    sshKey={key}
                    onEdit={onEdit}
                    onDelete={onDelete}
                    onAssign={onAssign}
                />
            ))}
        </div>
    );
};
