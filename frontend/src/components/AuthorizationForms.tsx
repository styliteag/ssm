import React, { useState, useEffect, useMemo } from 'react';
import { Check, UserPlus, AlertTriangle, Info } from 'lucide-react';
import { Authorization, AuthorizationFormData, User, Host } from '../types';
import Modal from './ui/Modal';
import Form, { FormField } from './ui/Form';
import Button from './ui/Button';
import { Card, CardContent, CardHeader, CardTitle } from './ui';
import { cn } from '../utils/cn';

// Add Authorization Modal
interface AddAuthorizationModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (data: AuthorizationFormData) => Promise<void>;
  users: User[];
  hosts: Host[];
  initialData?: Partial<AuthorizationFormData>;
  existingAuthorizations: Authorization[];
}

export const AddAuthorizationModal: React.FC<AddAuthorizationModalProps> = ({
  isOpen,
  onClose,
  onSubmit,
  users,
  hosts,
  initialData,
  existingAuthorizations,
}) => {
  const [loading, setLoading] = useState(false);
  const [selectedUserId, setSelectedUserId] = useState<number | null>(null);
  const [selectedHostId, setSelectedHostId] = useState<number | null>(null);

  // Check if authorization already exists
  const authorizationExists = useMemo(() => {
    if (!selectedUserId || !selectedHostId) return false;
    return existingAuthorizations.some(auth => 
      auth.user_id === selectedUserId && auth.host_id === selectedHostId
    );
  }, [selectedUserId, selectedHostId, existingAuthorizations]);

  const fields: FormField[] = [
    {
      name: 'user_id',
      label: 'User',
      type: 'select',
      required: true,
      options: users
        .filter(user => user.enabled)
        .map(user => ({
          value: user.id,
          label: user.username,
        })),
      placeholder: 'Select a user',
    },
    {
      name: 'host_id',
      label: 'Host',
      type: 'select',
      required: true,
      options: hosts.map(host => ({
        value: host.id,
        label: `${host.name} (${host.address})`,
      })),
      placeholder: 'Select a host',
    },
    {
      name: 'login',
      label: 'Login Account',
      type: 'text',
      required: true,
      placeholder: 'e.g., root, ubuntu, deploy',
      helperText: 'The username to use when connecting to the host',
    },
    {
      name: 'options',
      label: 'SSH Options',
      type: 'textarea',
      required: false,
      placeholder: 'e.g., no-pty,command="/bin/bash"',
      helperText: 'Optional SSH key options (advanced users only)',
      rows: 2,
    },
  ];

  const handleSubmit = async (values: Record<string, unknown>) => {
    setLoading(true);
    try {
      await onSubmit({
        user_id: parseInt(values.user_id as string),
        host_id: parseInt(values.host_id as string),
        login: (values.login as string).trim(),
        options: (values.options as string)?.trim() || undefined,
      });
      onClose();
    } catch (error) {
      console.error('Failed to create authorization:', error);
    } finally {
      setLoading(false);
    }
  };

  // Update selected values for duplicate check
  useEffect(() => {
    if (initialData?.user_id) setSelectedUserId(initialData.user_id);
    if (initialData?.host_id) setSelectedHostId(initialData.host_id);
  }, [initialData]);

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Grant User Access"
      size="md"
    >
      <div className="space-y-4">
        {authorizationExists && (
          <div className="flex items-start space-x-3 p-4 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg">
            <AlertTriangle className="h-5 w-5 text-yellow-500 flex-shrink-0 mt-0.5" />
            <div>
              <h4 className="text-sm font-medium text-yellow-800 dark:text-yellow-200">
                Authorization Already Exists
              </h4>
              <p className="text-sm text-yellow-700 dark:text-yellow-300 mt-1">
                This user already has access to the selected host. Creating this authorization will result in a duplicate.
              </p>
            </div>
          </div>
        )}

        <Form
          fields={fields}
          onSubmit={handleSubmit}
          initialValues={initialData}
          loading={loading}
          submitText="Grant Access"
          onCancel={onClose}
          layout="vertical"
        />
      </div>
    </Modal>
  );
};

// Edit Authorization Modal
interface EditAuthorizationModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (id: number, data: Partial<AuthorizationFormData>) => Promise<void>;
  authorization: Authorization | null;
  users: User[];
  hosts: Host[];
}

export const EditAuthorizationModal: React.FC<EditAuthorizationModalProps> = ({
  isOpen,
  onClose,
  onSubmit,
  authorization,
  users,
  hosts,
}) => {
  const [loading, setLoading] = useState(false);

  const fields: FormField[] = [
    {
      name: 'user_id',
      label: 'User',
      type: 'select',
      required: true,
      disabled: true, // Usually don't allow changing user/host in edit
      options: users.map(user => ({
        value: user.id,
        label: user.username,
        disabled: !user.enabled,
      })),
    },
    {
      name: 'host_id',
      label: 'Host',
      type: 'select',
      required: true,
      disabled: true, // Usually don't allow changing user/host in edit
      options: hosts.map(host => ({
        value: host.id,
        label: `${host.name} (${host.address})`,
      })),
    },
    {
      name: 'login',
      label: 'Login Account',
      type: 'text',
      required: true,
      placeholder: 'e.g., root, ubuntu, deploy',
      helperText: 'The username to use when connecting to the host',
    },
    {
      name: 'options',
      label: 'SSH Options',
      type: 'textarea',
      required: false,
      placeholder: 'e.g., no-pty,command="/bin/bash"',
      helperText: 'Optional SSH key options (advanced users only)',
      rows: 2,
    },
  ];

  const handleSubmit = async (values: Record<string, unknown>) => {
    if (!authorization) return;
    
    setLoading(true);
    try {
      await onSubmit(authorization.id, {
        login: (values.login as string).trim(),
        options: (values.options as string)?.trim() || undefined,
      });
      onClose();
    } catch (error) {
      console.error('Failed to update authorization:', error);
    } finally {
      setLoading(false);
    }
  };

  const initialValues = authorization ? {
    user_id: authorization.user_id,
    host_id: authorization.host_id,
    login: authorization.login,
    options: authorization.options || '',
  } : {};

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Edit Authorization"
      size="md"
    >
      <Form
        fields={fields}
        onSubmit={handleSubmit}
        initialValues={initialValues}
        loading={loading}
        submitText="Save Changes"
        onCancel={onClose}
        layout="vertical"
      />
    </Modal>
  );
};

// Bulk Grant Access Modal
interface BulkGrantModalProps {
  isOpen: boolean;
  onClose: () => void;
  onSubmit: (authorizations: AuthorizationFormData[]) => Promise<void>;
  users: User[];
  hosts: Host[];
  existingAuthorizations: Authorization[];
}

export const BulkGrantModal: React.FC<BulkGrantModalProps> = ({
  isOpen,
  onClose,
  onSubmit,
  users,
  hosts,
  existingAuthorizations,
}) => {
  const [loading, setLoading] = useState(false);
  const [selectedUsers, setSelectedUsers] = useState<Set<number>>(new Set());
  const [selectedHosts, setSelectedHosts] = useState<Set<number>>(new Set());
  const [login, setLogin] = useState('');
  const [options, setOptions] = useState('');

  // Calculate operations that would be performed
  const operations = useMemo(() => {
    const newAuthorizations: AuthorizationFormData[] = [];
    const existingCount = new Set<string>();
    
    for (const userId of selectedUsers) {
      for (const hostId of selectedHosts) {
        const existingAuth = existingAuthorizations.find(auth => 
          auth.user_id === userId && auth.host_id === hostId
        );
        
        if (existingAuth) {
          existingCount.add(`${userId}-${hostId}`);
        } else {
          newAuthorizations.push({
            user_id: userId,
            host_id: hostId,
            login: login.trim(),
            options: options.trim() || undefined,
          });
        }
      }
    }
    
    return {
      new: newAuthorizations,
      existing: existingCount.size,
      total: selectedUsers.size * selectedHosts.size,
    };
  }, [selectedUsers, selectedHosts, login, options, existingAuthorizations]);

  const handleSubmit = async () => {
    if (operations.new.length === 0) return;
    
    setLoading(true);
    try {
      await onSubmit(operations.new);
      onClose();
      // Reset form
      setSelectedUsers(new Set());
      setSelectedHosts(new Set());
      setLogin('');
      setOptions('');
    } catch (error) {
      console.error('Failed to create bulk authorizations:', error);
    } finally {
      setLoading(false);
    }
  };

  const toggleUser = (userId: number) => {
    setSelectedUsers(prev => {
      const newSet = new Set(prev);
      if (newSet.has(userId)) {
        newSet.delete(userId);
      } else {
        newSet.add(userId);
      }
      return newSet;
    });
  };

  const toggleHost = (hostId: number) => {
    setSelectedHosts(prev => {
      const newSet = new Set(prev);
      if (newSet.has(hostId)) {
        newSet.delete(hostId);
      } else {
        newSet.add(hostId);
      }
      return newSet;
    });
  };

  const enabledUsers = users.filter(user => user.enabled);

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Bulk Grant Access"
      size="xl"
    >
      <div className="space-y-6">
        <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
          {/* Users Selection */}
          <Card variant="elevated">
            <CardHeader>
              <CardTitle className="text-base">Select Users</CardTitle>
              <div className="flex items-center space-x-2">
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() => setSelectedUsers(new Set(enabledUsers.map(u => u.id)))}
                >
                  Select All
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() => setSelectedUsers(new Set())}
                >
                  Clear
                </Button>
              </div>
            </CardHeader>
            <CardContent>
              <div className="space-y-2 max-h-60 overflow-y-auto">
                {enabledUsers.map(user => (
                  <div
                    key={user.id}
                    className={cn(
                      'flex items-center space-x-2 p-2 rounded cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors',
                      selectedUsers.has(user.id) && 'bg-blue-50 dark:bg-blue-900/30 border border-blue-200 dark:border-blue-700'
                    )}
                    onClick={() => toggleUser(user.id)}
                  >
                    <div className={cn(
                      'w-4 h-4 rounded border-2 flex items-center justify-center transition-colors',
                      selectedUsers.has(user.id)
                        ? 'bg-blue-500 border-blue-500 dark:bg-blue-400 dark:border-blue-400'
                        : 'border-gray-300 dark:border-gray-500 bg-white dark:bg-gray-700'
                    )}>
                      {selectedUsers.has(user.id) && (
                        <Check size={12} className="text-white" />
                      )}
                    </div>
                    <span className="text-sm text-gray-900 dark:text-gray-100">{user.username}</span>
                  </div>
                ))}
              </div>
            </CardContent>
          </Card>

          {/* Hosts Selection */}
          <Card variant="elevated">
            <CardHeader>
              <CardTitle className="text-base">Select Hosts</CardTitle>
              <div className="flex items-center space-x-2">
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() => setSelectedHosts(new Set(hosts.map(h => h.id)))}
                >
                  Select All
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() => setSelectedHosts(new Set())}
                >
                  Clear
                </Button>
              </div>
            </CardHeader>
            <CardContent>
              <div className="space-y-2 max-h-60 overflow-y-auto">
                {hosts.map(host => (
                  <div
                    key={host.id}
                    className={cn(
                      'flex items-center space-x-2 p-2 rounded cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors',
                      selectedHosts.has(host.id) && 'bg-blue-50 dark:bg-blue-900/30 border border-blue-200 dark:border-blue-700'
                    )}
                    onClick={() => toggleHost(host.id)}
                  >
                    <div className={cn(
                      'w-4 h-4 rounded border-2 flex items-center justify-center transition-colors',
                      selectedHosts.has(host.id)
                        ? 'bg-blue-500 border-blue-500 dark:bg-blue-400 dark:border-blue-400'
                        : 'border-gray-300 dark:border-gray-500 bg-white dark:bg-gray-700'
                    )}>
                      {selectedHosts.has(host.id) && (
                        <Check size={12} className="text-white" />
                      )}
                    </div>
                    <div className="flex-1">
                      <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{host.name}</div>
                      <div className="text-xs text-gray-500 dark:text-gray-400">{host.address}</div>
                    </div>
                  </div>
                ))}
              </div>
            </CardContent>
          </Card>
        </div>

        {/* Access Configuration */}
        <Card variant="elevated">
          <CardHeader>
            <CardTitle className="text-base">Access Configuration</CardTitle>
          </CardHeader>
          <CardContent>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div className="space-y-2">
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
                  Login Account *
                </label>
                <input
                  type="text"
                  value={login}
                  onChange={(e) => setLogin(e.target.value)}
                  placeholder="e.g., root, ubuntu, deploy"
                  className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 focus:outline-none focus:ring-2 focus:ring-blue-500"
                  required
                />
              </div>
              <div className="space-y-2">
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
                  SSH Options
                </label>
                <input
                  type="text"
                  value={options}
                  onChange={(e) => setOptions(e.target.value)}
                  placeholder="Optional SSH key options"
                  className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 focus:outline-none focus:ring-2 focus:ring-blue-500"
                />
              </div>
            </div>
          </CardContent>
        </Card>

        {/* Operation Summary */}
        {(selectedUsers.size > 0 && selectedHosts.size > 0) && (
          <Card variant="elevated" className="bg-blue-50 dark:bg-blue-900/30 border-blue-200 dark:border-blue-700">
            <CardContent className="p-4">
            <div className="flex items-start space-x-3">
              <Info className="h-5 w-5 text-blue-500 flex-shrink-0 mt-0.5" />
              <div>
                <h4 className="text-sm font-medium text-blue-800 dark:text-blue-200">
                  Operation Summary
                </h4>
                <div className="text-sm text-blue-700 dark:text-blue-300 mt-1 space-y-1">
                  <div>• {operations.new.length} new authorizations will be created</div>
                  {operations.existing > 0 && (
                    <div>• {operations.existing} authorizations already exist (will be skipped)</div>
                  )}
                  <div>• Total operations: {operations.total}</div>
                </div>
              </div>
            </div>
            </CardContent>
          </Card>
        )}

        {/* Footer */}
        <div className="flex items-center justify-end space-x-3 pt-4 border-t border-gray-200 dark:border-gray-700">
          <Button variant="secondary" onClick={onClose} disabled={loading}>
            Cancel
          </Button>
          <Button
            onClick={handleSubmit}
            loading={loading}
            disabled={operations.new.length === 0 || !login.trim()}
            leftIcon={<UserPlus size={16} />}
          >
            Grant Access ({operations.new.length})
          </Button>
        </div>
      </div>
    </Modal>
  );
};

// Delete Confirmation Modal
interface DeleteAuthorizationModalProps {
  isOpen: boolean;
  onClose: () => void;
  onConfirm: () => Promise<void>;
  authorization: Authorization | null;
  user?: User;
  host?: Host;
}

export const DeleteAuthorizationModal: React.FC<DeleteAuthorizationModalProps> = ({
  isOpen,
  onClose,
  onConfirm,
  authorization,
  user,
  host,
}) => {
  const [loading, setLoading] = useState(false);

  const handleConfirm = async () => {
    setLoading(true);
    try {
      await onConfirm();
      onClose();
    } catch (error) {
      console.error('Failed to delete authorization:', error);
    } finally {
      setLoading(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Revoke Access"
      size="sm"
    >
      <div className="space-y-4">
        <div className="flex items-start space-x-3">
          <AlertTriangle className="h-6 w-6 text-red-500 flex-shrink-0 mt-1" />
          <div>
            <h3 className="text-lg font-medium text-gray-900 dark:text-white">
              Revoke User Access
            </h3>
            <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
              Are you sure you want to revoke access for{' '}
              <span className="font-medium">{user?.username || 'this user'}</span> to{' '}
              <span className="font-medium">{host?.name || 'this host'}</span>?
            </p>
            {authorization?.login && (
              <p className="text-sm text-gray-500 dark:text-gray-400 mt-2">
                Login account: <span className="font-mono bg-gray-100 dark:bg-gray-800 px-1 rounded">{authorization.login}</span>
              </p>
            )}
            <p className="text-sm text-red-600 dark:text-red-400 mt-2 font-medium">
              This action cannot be undone.
            </p>
          </div>
        </div>

        <div className="flex items-center justify-end space-x-3 pt-4">
          <Button variant="secondary" onClick={onClose} disabled={loading}>
            Cancel
          </Button>
          <Button
            onClick={handleConfirm}
            loading={loading}
            className="bg-red-600 hover:bg-red-700 text-white"
          >
            Revoke Access
          </Button>
        </div>
      </div>
    </Modal>
  );
};