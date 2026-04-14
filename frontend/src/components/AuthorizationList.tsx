import React, { useState, useMemo } from 'react';
import { Edit, Trash2, UserCheck, Shield, AlertTriangle } from 'lucide-react';
import { cn } from '../utils/cn';
import { Authorization, AuthorizationWithDetails, User, Host } from '../types';
import DataTable, { Column } from './ui/DataTable';
import Button from './ui/Button';

// Enhanced type that includes computed search fields
type EnhancedAuthorizationWithDetails = AuthorizationWithDetails & {
 user_name: string;
 host_name: string;
 host_address: string;
 host_search: string;
 status_text: string;
 login_search: string;
 combined_search: string;
 [key: string]: unknown;
};

interface AuthorizationListProps {
 authorizations: AuthorizationWithDetails[];
 users: User[];
 hosts: Host[];
 onEdit: (authorization: Authorization) => void;
 onDelete: (authorization: Authorization) => void;
 loading?: boolean;
 className?: string;
}

const AuthorizationList: React.FC<AuthorizationListProps> = ({
 authorizations,
 onEdit,
 onDelete,
 loading = false,
 className,
}) => {
 const [selectedAuthorizations, setSelectedAuthorizations] = useState<Set<number>>(new Set());

 // Create columns for the data table
 const columns: Column<EnhancedAuthorizationWithDetails>[] = useMemo(() => [
 {
 key: 'user_name',
 header: 'User',
 sortable: true,
 searchable: true,
 render: (_, auth) => (
 <div className="flex items-center space-x-2">
 <div className={cn(
 'w-2 h-2 rounded-full',
 auth.user?.enabled ? 'bg-success' : 'bg-destructive'
 )} />
 <span className={cn(
 'font-w510',
 !auth.user?.enabled && 'text-muted-foreground line-through'
 )}>
 {auth.user?.username || 'Unknown User'}
 </span>
 {!auth.user?.enabled && (
 <span className="text-xs text-muted-foreground bg-muted px-1 rounded">
 disabled
 </span>
 )}
 </div>
 ),
 },
 {
 key: 'host_search',
 header: 'Host',
 sortable: true,
 searchable: true,
 render: (_, auth) => (
 <div className="space-y-1">
 <div className="font-w510">{auth.host?.name || 'Unknown Host'}</div>
 <div className="text-sm text-muted-foreground">
 {auth.host?.address}
 {auth.host?.port && auth.host.port !== 22 && `:${auth.host.port}`}
 </div>
 </div>
 ),
 },
 {
 key: 'login',
 header: 'Login Account',
 sortable: true,
 searchable: true,
 render: (value) => (
 <span className="font-mono text-sm bg-muted px-2 py-1 rounded">
 {(value as string) || '-'}
 </span>
 ),
 },
 {
 key: 'options',
 header: 'SSH Options',
 sortable: false,
 searchable: true,
 render: (value) => (value as string) ? (
 <div className="max-w-xs">
 <div
 className="font-mono text-xs bg-muted p-2 rounded truncate"
 title={value as string}
 >
 {value as string}
 </div>
 </div>
 ) : (
 <span className="text-muted-foreground">None</span>
 ),
 },
 {
 key: 'comment',
 header: 'Comment',
 sortable: true,
 searchable: true,
 render: (value) => (
 <div className="max-w-xs">
 {(value as string) ? (
 <div
 className="text-sm bg-muted p-2 rounded truncate"
 title={value as string}
 >
 {value as string}
 </div>
 ) : (
 <span className="text-muted-foreground italic">No comment</span>
 )}
 </div>
 ),
 },
 {
 key: 'status_text',
 header: 'Status',
 sortable: true,
 searchable: true,
 render: (_, auth) => {
 const userEnabled = auth.user?.enabled ?? true;
 const hasValidUser = !!auth.user;
 const hasValidHost = !!auth.host;

 if (!hasValidUser || !hasValidHost) {
 return (
 <div className="flex items-center space-x-2">
 <AlertTriangle size={16} className="text-destructive" />
 <span className="text-destructive text-sm">Invalid</span>
 </div>
 );
 }

 if (!userEnabled) {
 return (
 <div className="flex items-center space-x-2">
 <Shield size={16} className="text-warning" />
 <span className="text-warning text-sm">User Disabled</span>
 </div>
 );
 }

 return (
 <div className="flex items-center space-x-2">
 <UserCheck size={16} className="text-success" />
 <span className="text-success text-sm">Active</span>
 </div>
 );
 },
 },
 {
 key: 'actions',
 header: 'Actions',
 sortable: false,
 width: '120px',
 render: (_, auth) => (
 <div className="flex items-center space-x-1">
 <Button
 size="sm"
 variant="ghost"
 onClick={() => onEdit(auth)}
 leftIcon={<Edit size={14} />}
 className="h-8 w-8 p-0"
 title="Edit authorization"
 />
 <Button
 size="sm"
 variant="ghost"
 onClick={() => onDelete(auth)}
 leftIcon={<Trash2 size={14} />}
 className="h-8 w-8 p-0 text-destructive hover:text-destructive hover:bg-destructive/10 dark:hover:bg-destructive/20"
 title="Delete authorization"
 />
 </div>
 ),
 },
 ], [onEdit, onDelete]);

 // Handle row selection
 const handleRowClick = (auth: EnhancedAuthorizationWithDetails) => {
 setSelectedAuthorizations(prev => {
 const newSet = new Set(prev);
 if (newSet.has(auth.id)) {
 newSet.delete(auth.id);
 } else {
 newSet.add(auth.id);
 }
 return newSet;
 });
 };

 // Enhanced data with computed fields for better searching and sorting
 const enhancedData = useMemo((): EnhancedAuthorizationWithDetails[] => {
 return authorizations.map(auth => ({
 ...auth,
 user_name: auth.user?.username || '',
 host_name: auth.host?.name || '',
 host_address: auth.host?.address || '',
 host_search: `${auth.host?.name || ''} ${auth.host?.address || ''}`.trim(),
 status_text: auth.user?.enabled ? 'Active' : 'Disabled',
 // Make login searchable as a string
 login_search: auth.login || '',
 // Combined search field for comprehensive searching
 combined_search: `${auth.user?.username || ''} ${auth.host?.name || ''} ${auth.host?.address || ''} ${auth.login || ''} ${auth.comment || ''} ${auth.user?.enabled ? 'Active' : 'Disabled'}`.toLowerCase(),
 }));
 }, [authorizations]);

 // Statistics for the data
 const stats = useMemo(() => {
 const totalAuthorizations = authorizations.length;
 const activeAuthorizations = authorizations.filter(auth => auth.user?.enabled).length;
 const uniqueUsers = new Set(authorizations.map(auth => auth.user_id)).size;
 const uniqueHosts = new Set(authorizations.map(auth => auth.host_id)).size;
 
 return {
 total: totalAuthorizations,
 active: activeAuthorizations,
 inactive: totalAuthorizations - activeAuthorizations,
 users: uniqueUsers,
 hosts: uniqueHosts,
 };
 }, [authorizations]);

 return (
 <div className={cn('space-y-4', className)}>
 {/* Statistics Header */}
 <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
 <div className="bg-card p-4 rounded-lg border border-border">
 <div className="text-sm font-w510 text-muted-foreground">Total</div>
 <div className="text-2xl font-w590 text-foreground">{stats.total}</div>
 </div>
 <div className="bg-card p-4 rounded-lg border border-border">
 <div className="text-sm font-w510 text-muted-foreground">Active</div>
 <div className="text-2xl font-w590 text-success">{stats.active}</div>
 </div>
 <div className="bg-card p-4 rounded-lg border border-border">
 <div className="text-sm font-w510 text-muted-foreground">Inactive</div>
 <div className="text-2xl font-w590 text-warning">{stats.inactive}</div>
 </div>
 <div className="bg-card p-4 rounded-lg border border-border">
 <div className="text-sm font-w510 text-muted-foreground">Users</div>
 <div className="text-2xl font-w590 text-primary">{stats.users}</div>
 </div>
 <div className="bg-card p-4 rounded-lg border border-border">
 <div className="text-sm font-w510 text-muted-foreground">Hosts</div>
 <div className="text-2xl font-w590 text-accent">{stats.hosts}</div>
 </div>
 </div>

 {/* Bulk Actions */}
 {selectedAuthorizations.size > 0 && (
 <div className="bg-primary/10 p-4 rounded-lg border border-primary/30 dark:border-primary/30">
 <div className="flex items-center justify-between">
 <span className="text-sm font-w510 text-primary ">
 {selectedAuthorizations.size} authorization(s) selected
 </span>
 <div className="flex items-center space-x-2">
 <Button
 size="sm"
 variant="secondary"
 onClick={() => {
 // Handle bulk delete
 const selectedAuths = authorizations.filter(auth => 
 selectedAuthorizations.has(auth.id)
 );
 selectedAuths.forEach(auth => onDelete(auth));
 setSelectedAuthorizations(new Set());
 }}
 leftIcon={<Trash2 size={14} />}
 className="text-destructive hover:text-destructive"
 >
 Delete Selected
 </Button>
 <Button
 size="sm"
 variant="ghost"
 onClick={() => setSelectedAuthorizations(new Set())}
 >
 Clear Selection
 </Button>
 </div>
 </div>
 </div>
 )}

 {/* Selection hint */}
 {authorizations.length > 0 && (
 <div className="text-xs text-muted-foreground text-center">
 Click rows to select multiple authorizations for bulk actions
 </div>
 )}

 {/* Data Table */}
 <DataTable
 data={enhancedData}
 columns={columns}
 loading={loading}
 searchable={true}
 sortable={true}
 paginated={true}
 pageSize={20}
 onRowClick={handleRowClick}
 emptyMessage="No authorizations found. Create some authorizations to get started."
 searchPlaceholder="Search authorizations by user, host, login, or comments..."
 className="bg-card rounded-lg border border-border"
 stickyHeader={true}
 initialSort={{ key: 'user_name', direction: 'asc' }}
 getItemId={(item) => item.id}
 getRowClassName={(item) => selectedAuthorizations.has(item.id) ? 'bg-primary/10' : ''}
 />
 </div>
 );
};

export default AuthorizationList;