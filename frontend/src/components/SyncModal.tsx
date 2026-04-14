import React, { useState } from 'react';
import { Upload, CheckCircle, RefreshCw } from 'lucide-react';
import { Modal, Button } from './ui';
import { DetailedDiffResponse } from '../services/api/diff';
import DiffIssue from './DiffIssue';

interface SyncModalProps {
 isOpen: boolean;
 onClose: () => void;
 hostDetails: DetailedDiffResponse | null;
 onSync: () => Promise<void>;
}

const SyncModal: React.FC<SyncModalProps> = ({ isOpen, onClose, hostDetails, onSync }) => {
 const [syncing, setSyncing] = useState(false);
 const [syncComplete, setSyncComplete] = useState(false);

 const handleSync = async () => {
 try {
 setSyncing(true);
 await onSync();
 setSyncComplete(true);
 // Auto-close after 2 seconds
 setTimeout(() => {
 setSyncComplete(false);
 onClose();
 }, 2000);
 } catch (error) {
 console.error('Sync failed:', error);
 } finally {
 setSyncing(false);
 }
 };

 const handleClose = () => {
 setSyncComplete(false);
 onClose();
 };

 if (!hostDetails) return null;

 const totalIssues = hostDetails.logins.reduce((sum, login) => sum + login.issues.length, 0);
 const hasIssues = totalIssues > 0;

 return (
 <Modal
 isOpen={isOpen}
 onClose={handleClose}
 title={`Sync SSH Keys - ${hostDetails.host.name}`}
 size="lg"
 >
 <div className="space-y-6">
 {/* Sync Status */}
 {syncComplete ? (
 <div className="bg-success/10 dark:bg-success/20 border border-success/30 dark:border-success/30 rounded-lg p-4">
 <div className="flex items-center space-x-3">
 <CheckCircle className="w-6 h-6 text-success dark:text-success" />
 <div>
 <h3 className="text-success font-w510">Sync Completed Successfully!</h3>
 <p className="text-success dark:text-success text-sm mt-1">
 SSH keys have been synchronized to {hostDetails.host.name}
 </p>
 </div>
 </div>
 </div>
 ) : (
 <>
 {/* Warning Header */}
 <div className="bg-primary/10 dark:bg-primary/20 border border-primary/30 dark:border-primary/30 rounded-lg p-4">
 <div className="flex items-start space-x-3">
 <Upload className="w-5 h-5 text-primary dark:text-primary mt-0.5" />
 <div>
 <h3 className="text-primary font-w510">Synchronization Preview</h3>
 <p className="text-primary dark:text-primary text-sm mt-1">
 The following actions will be performed on <strong>{hostDetails.host.name}</strong>:
 </p>
 </div>
 </div>
 </div>

 {/* Changes Summary */}
 <div className="bg-card rounded-lg border border-border p-4">
 <div className="flex items-center justify-between mb-4">
 <h4 className="text-lg font-w590 text-foreground">Changes to Apply</h4>
 <span className="inline-flex items-center px-3 py-1 rounded-full text-sm font-w510 bg-primary/10 dark:bg-primary/30 text-primary dark:text-primary">
 {totalIssues} {totalIssues === 1 ? 'change' : 'changes'}
 </span>
 </div>

 {!hasIssues ? (
 <div className="text-center py-8">
 <CheckCircle className="w-12 h-12 text-success mx-auto mb-3" />
 <p className="text-muted-foreground">No changes needed - all keys are already synchronized!</p>
 </div>
 ) : (
 <div className="max-h-96 overflow-y-auto space-y-4">
 {hostDetails.logins.map((loginDiff, loginIndex) => (
 <div key={loginIndex} className="border border-border rounded-lg overflow-hidden">
 <div className="bg-muted px-4 py-3 border-b border-border">
 <div className="flex items-center justify-between">
 <h5 className="text-sm font-w590 text-foreground flex items-center">
 <span className="text-muted-foreground mr-2">Login:</span>
 <code className="bg-primary/10 dark:bg-primary/50 text-primary px-2 py-1 rounded text-xs font-w590">{loginDiff.login}</code>
 </h5>
 <span className="text-xs text-muted-foreground bg-card px-2 py-1 rounded font-w510">
 {loginDiff.issues.length} action{loginDiff.issues.length !== 1 ? 's' : ''}
 </span>
 </div>
 {loginDiff.readonly_condition && (
 <div className="text-xs text-warning dark:text-warning mt-2 flex items-center">
 <span className="mr-1">🔒</span>
 <span className="font-w510">Readonly:</span>
 <span className="ml-1">{loginDiff.readonly_condition}</span>
 </div>
 )}
 </div>
 <div className="p-4 space-y-3">
 {loginDiff.issues.map((issue, issueIndex) => (
 <div key={issueIndex}>
 <DiffIssue issue={issue} />
 </div>
 ))}
 </div>
 </div>
 ))}
 </div>
 )}
 </div>

 {/* Action Buttons */}
 <div className="flex justify-between items-center pt-4 border-t border-border">
 <div className="text-sm text-muted-foreground">
 {hasIssues ? (
 <>This will modify authorized_keys files on the remote host.</>
 ) : (
 <>No changes will be made as the host is already synchronized.</>
 )}
 </div>
 <div className="flex space-x-3">
 <Button
 onClick={handleClose}
 variant="secondary"
 disabled={syncing}
 >
 Cancel
 </Button>
 <Button
 onClick={handleSync}
 loading={syncing}
 disabled={!hasIssues}
 leftIcon={syncing ? <RefreshCw size={16} /> : <Upload size={16} />}
 variant="primary"
 className="bg-primary hover:bg-primary"
 >
 {syncing ? 'Synchronizing...' : 'Apply Changes'}
 </Button>
 </div>
 </div>
 </>
 )}
 </div>
 </Modal>
 );
};

export default SyncModal;