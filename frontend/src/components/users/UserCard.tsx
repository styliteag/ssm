import React from 'react';
import { User, Key, Shield, Edit2, Trash2, UserMinus, UserPlus, Split } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle, Button } from '../ui';
import { cn } from '../../utils/cn';
import { User as UserType } from '../../types';

interface ExtendedUser extends UserType {
    keyCount?: number;
    authorizationCount?: number;
    [key: string]: unknown;
}

interface UserCardProps {
    user: ExtendedUser;
    onEdit: (user: ExtendedUser) => void;
    onDelete: (user: ExtendedUser) => void;
    onToggleStatus: (user: ExtendedUser) => void;
    onViewKeys: (user: ExtendedUser) => void;
    onViewAuths: (user: ExtendedUser) => void;
    onSplitKeys: (user: ExtendedUser) => void;
}

export const UserCard: React.FC<UserCardProps> = ({
    user,
    onEdit,
    onDelete,
    onToggleStatus,
    onViewKeys,
    onViewAuths,
    onSplitKeys
}) => {
    const statusColor = user.enabled ? 'bg-green-500' : 'bg-red-500';
    const statusText = user.enabled ? 'Active' : 'Disabled';

    return (
        <Card className="group hover:shadow-lg transition-all duration-300 border-border/50 bg-card/50 backdrop-blur-sm">
            <CardHeader className="flex flex-row items-start justify-between space-y-0 pb-2">
                <div className="flex items-center space-x-3">
                    <div className={cn(
                        "p-2 rounded-lg transition-colors duration-300",
                        user.enabled ? "bg-primary/10 text-primary group-hover:bg-primary group-hover:text-primary-foreground" : "bg-muted text-muted-foreground"
                    )}>
                        <User size={20} />
                    </div>
                    <div>
                        <CardTitle className="text-base font-semibold">{user.username}</CardTitle>
                        <div className="flex items-center text-xs text-muted-foreground mt-1">
                            <span className={cn("w-2 h-2 rounded-full mr-2", statusColor)} />
                            <span className="capitalize">{statusText}</span>
                        </div>
                    </div>
                </div>
                <div className="flex space-x-1 opacity-0 group-hover:opacity-100 transition-opacity duration-200">
                    <Button
                        variant="ghost"
                        size="sm"
                        className="h-8 w-8 p-0"
                        onClick={() => onToggleStatus(user)}
                        title={user.enabled ? "Disable User" : "Enable User"}
                    >
                        {user.enabled ? <UserMinus size={14} /> : <UserPlus size={14} />}
                    </Button>
                    <Button variant="ghost" size="sm" className="h-8 w-8 p-0" onClick={() => onEdit(user)}>
                        <Edit2 size={14} />
                    </Button>
                    <Button variant="ghost" size="sm" className="h-8 w-8 p-0 text-destructive hover:text-destructive" onClick={() => onDelete(user)}>
                        <Trash2 size={14} />
                    </Button>
                </div>
            </CardHeader>
            <CardContent>
                <div className="grid grid-cols-2 gap-4 mb-4">
                    <div
                        className="flex flex-col items-center justify-center p-3 rounded-lg bg-secondary/30 hover:bg-secondary/50 transition-colors cursor-pointer border border-border/50"
                        onClick={() => onViewKeys(user)}
                    >
                        <Key size={16} className="mb-1 text-primary" />
                        <span className="text-lg font-bold">{user.keyCount || 0}</span>
                        <span className="text-xs text-muted-foreground">SSH Keys</span>
                    </div>
                    <div
                        className="flex flex-col items-center justify-center p-3 rounded-lg bg-secondary/30 hover:bg-secondary/50 transition-colors cursor-pointer border border-border/50"
                        onClick={() => onViewAuths(user)}
                    >
                        <Shield size={16} className="mb-1 text-green-600 dark:text-green-400" />
                        <span className="text-lg font-bold">{user.authorizationCount || 0}</span>
                        <span className="text-xs text-muted-foreground">Hosts</span>
                    </div>
                </div>

                {user.comment && (
                    <p className="text-xs text-muted-foreground mb-4 line-clamp-2 min-h-[2.5em]">
                        {user.comment}
                    </p>
                )}

                {(user.keyCount || 0) > 1 && (
                    <Button
                        variant="outline"
                        size="sm"
                        className="w-full text-xs"
                        onClick={() => onSplitKeys(user)}
                    >
                        <Split size={12} className="mr-2" />
                        Split Keys
                    </Button>
                )}
            </CardContent>
        </Card>
    );
};
