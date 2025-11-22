import React from 'react';
import { Key, User, Shield, Edit2, Trash2, UserPlus, Copy, CheckCircle, AlertCircle, XCircle, Clock } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle, Button } from '../ui';
import { cn } from '../../utils/cn';
import { PublicUserKey } from '../../types';

interface ExtendedKey extends PublicUserKey {
    username?: string;
    fingerprint?: string;
    status: 'deployed' | 'pending' | 'error' | 'unknown';
    lastUsed?: Date;
    createdAt?: Date;
    hostCount?: number;
    [key: string]: unknown;
}

interface KeyCardProps {
    sshKey: ExtendedKey;
    onEdit: (key: ExtendedKey) => void;
    onDelete: (key: ExtendedKey) => void;
    onAssign: (key: ExtendedKey) => void;
}

export const KeyCard: React.FC<KeyCardProps> = ({
    sshKey,
    onEdit,
    onDelete,
    onAssign
}) => {
    const isAssigned = sshKey.user_id && sshKey.user_id !== 0;

    const getStatusIcon = (status: ExtendedKey['status']) => {
        switch (status) {
            case 'deployed':
                return <CheckCircle size={14} className="text-green-500" />;
            case 'pending':
                return <Clock size={14} className="text-yellow-500" />;
            case 'error':
                return <XCircle size={14} className="text-red-500" />;
            default:
                return <AlertCircle size={14} className="text-muted-foreground" />;
        }
    };

    const getKeyTypeColor = (keyType: string) => {
        switch (keyType) {
            case 'ssh-rsa':
                return 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-300';
            case 'ssh-ed25519':
                return 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-300';
            case 'ecdsa-sha2-nistp256':
            case 'ecdsa-sha2-nistp384':
            case 'ecdsa-sha2-nistp521':
                return 'bg-purple-100 text-purple-800 dark:bg-purple-900/30 dark:text-purple-300';
            default:
                return 'bg-gray-100 text-gray-800 dark:bg-gray-800 dark:text-gray-300';
        }
    };

    const copyToClipboard = async (text: string) => {
        try {
            await navigator.clipboard.writeText(text);
            // Ideally show a toast here, but we'll rely on the parent or just silent success for now
        } catch (err) {
            console.error('Failed to copy:', err);
        }
    };

    return (
        <Card className="group hover:shadow-lg transition-all duration-300 border-border/50 bg-card/50 backdrop-blur-sm">
            <CardHeader className="flex flex-row items-start justify-between space-y-0 pb-2">
                <div className="flex items-center space-x-3 overflow-hidden">
                    <div className={cn(
                        "p-2 rounded-lg transition-colors duration-300 flex-shrink-0",
                        "bg-primary/10 text-primary group-hover:bg-primary group-hover:text-primary-foreground"
                    )}>
                        <Key size={20} />
                    </div>
                    <div className="min-w-0">
                        <CardTitle className="text-base font-semibold truncate">
                            {sshKey.key_name || 'Unnamed Key'}
                        </CardTitle>
                        <div className="flex items-center text-xs text-muted-foreground mt-1 space-x-2">
                            <span className={cn("px-1.5 py-0.5 rounded text-[10px] font-medium uppercase", getKeyTypeColor(sshKey.key_type))}>
                                {sshKey.key_type.replace('ssh-', '')}
                            </span>
                            <div className="flex items-center space-x-1">
                                {getStatusIcon(sshKey.status)}
                                <span className="capitalize">{sshKey.status}</span>
                            </div>
                        </div>
                    </div>
                </div>
                <div className="flex space-x-1 opacity-0 group-hover:opacity-100 transition-opacity duration-200">
                    <Button
                        variant="ghost"
                        size="sm"
                        className="h-8 w-8 p-0"
                        onClick={() => copyToClipboard(`${sshKey.key_type} ${sshKey.key_base64}`)}
                        title="Copy Public Key"
                    >
                        <Copy size={14} />
                    </Button>
                    <Button variant="ghost" size="sm" className="h-8 w-8 p-0" onClick={() => onEdit(sshKey)}>
                        <Edit2 size={14} />
                    </Button>
                    <Button variant="ghost" size="sm" className="h-8 w-8 p-0 text-destructive hover:text-destructive" onClick={() => onDelete(sshKey)}>
                        <Trash2 size={14} />
                    </Button>
                </div>
            </CardHeader>
            <CardContent>
                <div className="grid grid-cols-2 gap-4 mb-4">
                    <div className="flex flex-col p-3 rounded-lg bg-secondary/30 border border-border/50">
                        <div className="flex items-center space-x-2 mb-1">
                            <User size={14} className="text-muted-foreground" />
                            <span className="text-xs font-medium text-muted-foreground">Assigned To</span>
                        </div>
                        <span className={cn("text-sm font-semibold truncate", !isAssigned && "text-muted-foreground italic")}>
                            {isAssigned ? sshKey.username : 'Unassigned'}
                        </span>
                    </div>
                    <div className="flex flex-col p-3 rounded-lg bg-secondary/30 border border-border/50">
                        <div className="flex items-center space-x-2 mb-1">
                            <Shield size={14} className="text-muted-foreground" />
                            <span className="text-xs font-medium text-muted-foreground">Access</span>
                        </div>
                        <span className="text-sm font-semibold">
                            {sshKey.hostCount || 0} Hosts
                        </span>
                    </div>
                </div>

                {sshKey.extra_comment && (
                    <p className="text-xs text-muted-foreground mb-4 line-clamp-2 min-h-[2.5em] bg-muted/30 p-2 rounded border border-border/30">
                        {sshKey.extra_comment}
                    </p>
                )}

                {!isAssigned && (
                    <Button
                        variant="outline"
                        size="sm"
                        className="w-full text-xs border-dashed"
                        onClick={() => onAssign(sshKey)}
                    >
                        <UserPlus size={12} className="mr-2" />
                        Assign to User
                    </Button>
                )}
            </CardContent>
        </Card>
    );
};
