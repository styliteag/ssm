import React from 'react';
import { User as UserType } from '../../types';
import { UserCard } from './UserCard';

interface ExtendedUser extends UserType {
    keyCount?: number;
    authorizationCount?: number;
    [key: string]: unknown;
}

interface UserGridProps {
    users: ExtendedUser[];
    onEdit: (user: ExtendedUser) => void;
    onDelete: (user: ExtendedUser) => void;
    onToggleStatus: (user: ExtendedUser) => void;
    onViewKeys: (user: ExtendedUser) => void;
    onViewAuths: (user: ExtendedUser) => void;
    onSplitKeys: (user: ExtendedUser) => void;
}

export const UserGrid: React.FC<UserGridProps> = ({
    users,
    onEdit,
    onDelete,
    onToggleStatus,
    onViewKeys,
    onViewAuths,
    onSplitKeys
}) => {
    if (users.length === 0) {
        return (
            <div className="text-center py-12 text-muted-foreground">
                No users found. Add one to get started.
            </div>
        );
    }

    return (
        <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-6 animate-in fade-in duration-500">
            {users.map((user) => (
                <UserCard
                    key={user.id}
                    user={user}
                    onEdit={onEdit}
                    onDelete={onDelete}
                    onToggleStatus={onToggleStatus}
                    onViewKeys={onViewKeys}
                    onViewAuths={onViewAuths}
                    onSplitKeys={onSplitKeys}
                />
            ))}
        </div>
    );
};
