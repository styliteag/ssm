import React, { useState } from 'react';
import { 
 CheckCircle, 
 AlertCircle, 
 Plus, 
 Minus, 
 Edit3, 
 Eye,
 Key,
 User
} from 'lucide-react';
import { cn } from '../../utils/cn';
import { KeyDifference } from '../../types';
import { Button, Card } from '../ui';
import type { Column } from '../ui/DataTable';

export interface KeyDiffTableProps {
 differences: KeyDifference[];
 hostName: string;
 onSelectDifference?: (difference: KeyDifference, selected: boolean) => void;
 selectedDifferences?: Set<number>;
 selectable?: boolean;
 className?: string;
 showDetails?: boolean;
}

interface KeyDiffRow extends KeyDifference {
 id: number;
 fingerprint: string;
 user_display: string;
 status_display: string;
 key_preview: string;
 [key: string]: unknown;
}

const KeyDiffTable: React.FC<KeyDiffTableProps> = ({
 differences,
 hostName,
 onSelectDifference,
 selectedDifferences = new Set(),
 selectable = false,
 className,
 showDetails = true,
}) => {
 const [expandedRow, setExpandedRow] = useState<number | null>(null);

 // Transform differences into table rows
 const tableData: KeyDiffRow[] = differences.map((diff, index) => {
 const allowedUser = diff.key;
 const fingerprint = generateKeyFingerprint(allowedUser.key.key_base64);
 
 return {
 ...diff,
 id: index,
 fingerprint,
 user_display: allowedUser.username,
 status_display: getStatusDisplay(diff.action),
 key_preview: `${allowedUser.key.key_type} ${allowedUser.key.key_base64.substring(0, 20)}...`,
 };
 });

 function generateKeyFingerprint(keyBase64: string): string {
 // Simple fingerprint generation (in real app, you'd use proper SSH key fingerprint)
 return `SHA256:${keyBase64.substring(0, 8)}...${keyBase64.substring(-8)}`;
 }

 function getStatusDisplay(action: KeyDifference['action']): string {
 switch (action) {
 case 'add':
 return 'Missing';
 case 'remove':
 return 'Extra';
 case 'modify':
 return 'Modified';
 default:
 return action;
 }
 }

 const getActionIcon = (action: KeyDifference['action']) => {
 switch (action) {
 case 'add':
 return <Plus size={16} className="text-success dark:text-success" />;
 case 'remove':
 return <Minus size={16} className="text-destructive dark:text-destructive" />;
 case 'modify':
 return <Edit3 size={16} className="text-warning dark:text-warning" />;
 default:
 return <AlertCircle size={16} className="text-muted-foreground" />;
 }
 };

 const getActionBadge = (action: KeyDifference['action']) => {
 const baseClasses = "inline-flex items-center px-2 py-1 rounded-full text-xs font-w510";
 
 switch (action) {
 case 'add':
 return (
 <span className={cn(baseClasses, "bg-success/10 text-success dark:bg-success/20 dark:text-success")}>
 <Plus size={12} className="mr-1" />
 Add Key
 </span>
 );
 case 'remove':
 return (
 <span className={cn(baseClasses, "bg-destructive/10 text-destructive dark:bg-destructive/20 dark:text-destructive")}>
 <Minus size={12} className="mr-1" />
 Remove Key
 </span>
 );
 case 'modify':
 return (
 <span className={cn(baseClasses, "bg-warning/10 text-warning dark:bg-warning/20 dark:text-warning")}>
 <Edit3 size={12} className="mr-1" />
 Modify Key
 </span>
 );
 default:
 return (
 <span className={cn(baseClasses, "bg-muted text-foreground")}>
 Unknown
 </span>
 );
 }
 };

 const KeyDetailCard: React.FC<{ difference: KeyDifference; isExpected?: boolean }> = ({ 
 difference, 
 isExpected = true 
 }) => {
 const allowedUser = isExpected ? difference.key : difference.existing_key;
 if (!allowedUser) return null;

 return (
 <Card className="p-4 space-y-3">
 <div className="flex items-center space-x-2">
 <Key size={16} className="text-muted-foreground" />
 <span className="font-w510 text-foreground">
 {isExpected ? 'Expected Key' : 'Actual Key'}
 </span>
 </div>
 
 <div className="space-y-2 text-sm">
 <div className="grid grid-cols-3 gap-4">
 <div>
 <span className="text-muted-foreground">Type:</span>
 <div className="font-mono text-foreground">{allowedUser.key.key_type}</div>
 </div>
 <div>
 <span className="text-muted-foreground">User:</span>
 <div className="flex items-center space-x-1">
 <User size={14} />
 <span className="text-foreground">{allowedUser.username}</span>
 </div>
 </div>
 <div>
 <span className="text-muted-foreground">Login:</span>
 <div className="text-foreground">{allowedUser.login}</div>
 </div>
 </div>
 
 {allowedUser.options && (
 <div>
 <span className="text-muted-foreground">Options:</span>
 <div className="font-mono text-sm bg-muted p-2 rounded mt-1">
 {allowedUser.options}
 </div>
 </div>
 )}
 
 <div>
 <span className="text-muted-foreground">Public Key:</span>
 <div className="font-mono text-sm bg-muted p-2 rounded mt-1 break-all">
 {allowedUser.key.key_type} {allowedUser.key.key_base64} {allowedUser.key.key_name || ''}
 </div>
 </div>
 
 <div>
 <span className="text-muted-foreground">Fingerprint:</span>
 <div className="font-mono text-sm text-foreground">
 {generateKeyFingerprint(allowedUser.key.key_base64)}
 </div>
 </div>
 </div>
 </Card>
 );
 };

 const columns: Column<KeyDiffRow>[] = [
 ...(selectable ? [{
 key: 'actions',
 header: '',
 width: '50px',
 sortable: false,
 render: (_: unknown, item: KeyDiffRow) => (
 <input
 type="checkbox"
 checked={selectedDifferences.has(item.id)}
 onChange={(e) => onSelectDifference?.(item, e.target.checked)}
 className="rounded border-border text-primary focus:ring-ring"
 />
 ),
 }] : []),
 {
 key: 'action',
 header: 'Action',
 width: '120px',
 render: (_: unknown, item: KeyDiffRow) => getActionBadge(item.action),
 },
 {
 key: 'user_display',
 header: 'User',
 width: '150px',
 render: (value: unknown) => (
 <div className="flex items-center space-x-2">
 <User size={16} className="text-muted-foreground" />
 <span className="font-w510">{value as string}</span>
 </div>
 ),
 },
 {
 key: 'key',
 header: 'Key Type',
 width: '100px',
 render: (_: unknown, item: KeyDiffRow) => (
 <span className="font-mono text-sm">{item.key.key.key_type}</span>
 ),
 },
 {
 key: 'fingerprint',
 header: 'Fingerprint',
 width: '200px',
 render: (value: unknown) => (
 <span className="font-mono text-sm text-muted-foreground">
 {value as string}
 </span>
 ),
 },
 {
 key: 'key',
 header: 'Login',
 width: '120px',
 render: (_: unknown, item: KeyDiffRow) => item.key.login,
 },
 {
 key: 'key',
 header: 'Comment',
 render: (_: unknown, item: KeyDiffRow) => (
 <span className="text-sm text-muted-foreground">
 {item.key.key.key_name || <em>No comment</em>}
 </span>
 ),
 },
 ...(showDetails ? [{
 key: 'actions',
 header: '',
 width: '80px',
 sortable: false,
 render: (_: unknown, item: KeyDiffRow) => (
 <Button
 variant="ghost"
 size="sm"
 onClick={() => setExpandedRow(expandedRow === item.id ? null : item.id)}
 leftIcon={<Eye size={16} />}
 >
 {expandedRow === item.id ? 'Hide' : 'View'}
 </Button>
 ),
 }] : []),
 ];

 const ExpandedRowContent: React.FC<{ difference: KeyDifference }> = ({ difference }) => (
 <tr>
 <td colSpan={columns.length} className="p-0">
 <div className="bg-muted p-6 space-y-4">
 <div className="flex items-center space-x-2 mb-4">
 {getActionIcon(difference.action)}
 <h4 className="text-lg font-w510 text-foreground">
 Key Details - {getStatusDisplay(difference.action)}
 </h4>
 </div>
 
 <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
 <KeyDetailCard difference={difference} isExpected={true} />
 {difference.existing_key && difference.action === 'modify' && (
 <KeyDetailCard difference={difference} isExpected={false} />
 )}
 </div>
 
 {difference.action === 'modify' && difference.existing_key && (
 <div className="mt-4 p-4 bg-warning/10 dark:bg-warning/20 rounded-lg">
 <h5 className="font-w510 text-warning mb-2">
 What will change:
 </h5>
 <ul className="text-sm text-warning dark:text-warning space-y-1">
 {difference.key.key.key_name !== difference.existing_key.key.key_name && (
 <li>• Comment: "{difference.existing_key.key.key_name || 'none'}" → "{difference.key.key.key_name || 'none'}"</li>
 )}
 {difference.key.options !== difference.existing_key.options && (
 <li>• Options: "{difference.existing_key.options || 'none'}" → "{difference.key.options || 'none'}"</li>
 )}
 {difference.key.login !== difference.existing_key.login && (
 <li>• Login: "{difference.existing_key.login}" → "{difference.key.login}"</li>
 )}
 </ul>
 </div>
 )}
 </div>
 </td>
 </tr>
 );

 if (differences.length === 0) {
 return (
 <div className={cn('text-center py-8', className)}>
 <CheckCircle size={48} className="mx-auto text-success dark:text-success mb-4" />
 <h3 className="text-lg font-w510 text-foreground mb-2">
 No Key Differences Found
 </h3>
 <p className="text-muted-foreground">
 All SSH keys on {hostName} are synchronized with the expected configuration.
 </p>
 </div>
 );
 }

 return (
 <div className={className}>
 <div className="mb-4">
 <h3 className="text-lg font-w510 text-foreground mb-2">
 Key-Level Analysis
 </h3>
 <div className="flex items-center space-x-4 text-sm text-muted-foreground">
 <span className="flex items-center space-x-1">
 <Plus size={16} className="text-success dark:text-success" />
 <span>{differences.filter(d => d.action === 'add').length} keys to add</span>
 </span>
 <span className="flex items-center space-x-1">
 <Minus size={16} className="text-destructive dark:text-destructive" />
 <span>{differences.filter(d => d.action === 'remove').length} keys to remove</span>
 </span>
 <span className="flex items-center space-x-1">
 <Edit3 size={16} className="text-warning dark:text-warning" />
 <span>{differences.filter(d => d.action === 'modify').length} keys to modify</span>
 </span>
 </div>
 </div>

 <div className="overflow-hidden rounded-lg border border-border">
 <table className="min-w-full divide-y divide-border">
 <thead className="bg-muted">
 <tr>
 {columns.map((column) => (
 <th
 key={String(column.key)}
 className={cn(
 'px-6 py-3 text-left text-xs font-w510 text-muted-foreground uppercase tracking-wider',
 column.headerClassName
 )}
 style={{ width: column.width }}
 >
 {column.header}
 </th>
 ))}
 </tr>
 </thead>
 <tbody className="bg-card divide-y divide-border">
 {tableData.map((item) => (
 <React.Fragment key={item.id}>
 <tr className="hover:bg-muted/50 transition-colors">
 {columns.map((column) => (
 <td
 key={String(column.key)}
 className={cn(
 'px-6 py-4 whitespace-nowrap text-sm text-foreground',
 column.className
 )}
 >
 {column.render ? (
 column.render(
 column.key === 'actions' ? item : item[column.key as keyof KeyDiffRow],
 item,
 0
 )
 ) : (
 String(item[column.key as keyof KeyDiffRow] || '')
 )}
 </td>
 ))}
 </tr>
 {expandedRow === item.id && (
 <ExpandedRowContent difference={item} />
 )}
 </React.Fragment>
 ))}
 </tbody>
 </table>
 </div>
 </div>
 );
};

export default KeyDiffTable;