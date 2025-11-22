import React, { useState, useEffect, useCallback, useMemo } from 'react';
import {
  Key,
  Plus,
  Edit2,
  Trash2,
  Copy,
  UserCheck,
  UserX,
  UserPlus,
  Shield,
  AlertCircle,
  CheckCircle,
  XCircle,
  Clock,
  Upload,
  Users,
  LayoutGrid,
  List,
  Search
} from 'lucide-react';
import { cn } from '../utils/cn';
import {
  Card,
  CardContent,
  Button,
  DataTable,
  Modal,
  Form,
  Input,
  type Column,
  type FormField
} from '../components/ui';
import { useNotifications } from '../contexts/NotificationContext';
import { keysService } from '../services/api/keys';
import { usersService } from '../services/api/users';
import { authorizationsService } from '../services/api/authorizations';
import UserEditModal from '../components/UserEditModal';
import { KeyGrid } from '../components/keys/KeyGrid';
import type {
  PublicUserKey,
  User,
  Authorization,
  Host
} from '../types';

interface ExtendedKey extends PublicUserKey {
  username?: string;
  fingerprint?: string;
  status: 'deployed' | 'pending' | 'error' | 'unknown';
  lastUsed?: Date;
  createdAt?: Date;
  hostCount?: number;
  [key: string]: unknown;
}

interface KeyDetails {
  authorizations: Authorization[];
  hosts: Host[];
}

interface KeyFilters {
  keyType?: string;
  userId?: number;
  status?: 'all' | 'assigned' | 'unassigned';
}

const KeysPage: React.FC = () => {
  const { showSuccess, showError } = useNotifications();

  // State management
  const [keys, setKeys] = useState<ExtendedKey[]>([]);
  const [users, setUsers] = useState<User[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedKeys] = useState<number[]>([]);
  const [selectedKey, setSelectedKey] = useState<ExtendedKey | null>(null);
  const [keyDetails, setKeyDetails] = useState<KeyDetails | null>(null);
  const [filters, setFilters] = useState<KeyFilters>({});
  const [editingUser, setEditingUser] = useState<User | null>(null);
  const [viewMode, setViewMode] = useState<'list' | 'grid'>('list');
  const [searchTerm, setSearchTerm] = useState('');

  // Modal states
  const [showAddModal, setShowAddModal] = useState(false);
  const [showDeleteModal, setShowDeleteModal] = useState(false);
  const [showViewModal, setShowViewModal] = useState(false);
  const [showAssignModal, setShowAssignModal] = useState(false);
  const [showBulkAssignModal, setShowBulkAssignModal] = useState(false);
  const [showImportModal, setShowImportModal] = useState(false);
  const [showUserEditModal, setShowUserEditModal] = useState(false);

  // Edit state for inline key name and comment editing
  const [editingKeyName, setEditingKeyName] = useState(false);
  const [editingExtraComment, setEditingExtraComment] = useState(false);
  const [keyNameValue, setKeyNameValue] = useState('');
  const [extraCommentValue, setExtraCommentValue] = useState('');

  // Form loading states
  const [submitting, setSubmitting] = useState(false);
  const [loadingDetails, setLoadingDetails] = useState(false);

  // SSH key validation regex
  const SSH_KEY_REGEX = /^(ssh-rsa|ssh-dss|ssh-ed25519|ecdsa-sha2-nistp[0-9]+)\s+[A-Za-z0-9+/]+[=]{0,3}(\s+.*)?$/;

  // Load keys with extended information
  const loadKeys = useCallback(async () => {
    try {
      setLoading(true);
      const [keysResponse, usersResponse] = await Promise.all([
        keysService.getKeys({ per_page: 100 }),
        usersService.getUsers({ per_page: 100 })
      ]);

      if (keysResponse.success && keysResponse.data && usersResponse.success && usersResponse.data) {
        // Create user lookup maps - both id->user and username->user
        const userMap = new Map(usersResponse.data.items.map(user => [user.id, user]));
        const usernameMap = new Map(usersResponse.data.items.map(user => [user.username, user]));
        setUsers(usersResponse.data.items);

        // Enhance keys with additional information
        const enhancedKeys = await Promise.all(
          keysResponse.data.items.map(async (key): Promise<ExtendedKey> => {
            try {
              // Backend returns username instead of user_id, so we need to map it back
              const keyWithUsername = key as PublicUserKey & { username?: string };
              const user = keyWithUsername.username ? usernameMap.get(keyWithUsername.username) : userMap.get(key.user_id);
              const actualUsername = keyWithUsername.username || user?.username || 'Unknown';

              // Get authorization count for this key
              const authResponse = await authorizationsService.getUserAuthorizations(actualUsername);
              const hostCount = authResponse.success ? authResponse.data?.length || 0 : 0;

              return {
                ...key,
                user_id: user?.id || 0, // Set proper user_id from the username lookup
                username: actualUsername,
                status: 'deployed', // Would be determined by backend logic
                hostCount,
                createdAt: new Date(), // Would come from backend
              };
            } catch {
              // Fallback for error cases
              const keyWithUsername = key as PublicUserKey & { username?: string };
              const user = keyWithUsername.username ? usernameMap.get(keyWithUsername.username) : userMap.get(key.user_id);
              const actualUsername = keyWithUsername.username || user?.username || 'Unknown';

              return {
                ...key,
                user_id: user?.id || 0,
                username: actualUsername,
                status: 'unknown',
                hostCount: 0,
                createdAt: new Date(),
              };
            }
          })
        );

        setKeys(enhancedKeys);
      }
    } catch {
      showError('Failed to load SSH keys', 'Please try again later');
    } finally {
      setLoading(false);
    }
  }, [showError]);

  useEffect(() => {
    loadKeys();
  }, [loadKeys]);

  // Load key details (authorizations and hosts)
  // @ts-ignore - Keeping this for future use
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  const loadKeyDetails = useCallback(async (keyId: number) => {
    try {
      setLoadingDetails(true);
      const key = keys.find(k => k.id === keyId);
      if (!key) return;

      const authResponse = await authorizationsService.getUserAuthorizations(key.username || '');
      if (authResponse.success && authResponse.data) {
        // Would need to fetch host details in a real implementation
        const hosts: Host[] = []; // Would need to fetch host details

        setKeyDetails({
          authorizations: authResponse.data,
          hosts
        });
      }
    } catch {
      showError('Failed to load key details', 'Please try again');
    } finally {
      setLoadingDetails(false);
    }
  }, [keys, showError]);

  // Validate SSH key format
  const validateSSHKey = (keyText: string): { valid: boolean; message?: string } => {
    if (!keyText.trim()) {
      return { valid: false, message: 'SSH key is required' };
    }

    if (!SSH_KEY_REGEX.test(keyText.trim())) {
      return {
        valid: false,
        message: 'Invalid SSH key format. Expected format: ssh-rsa/ssh-ed25519/ecdsa-sha2-... [key] [comment]'
      };
    }

    return { valid: true };
  };

  // Parse SSH key text into components
  const parseSSHKey = (keyText: string) => {
    const parts = keyText.trim().split(/\s+/);
    if (parts.length < 2) return null;

    return {
      key_type: parts[0],
      key_base64: parts[1],
      key_name: parts.slice(2).join(' ') || undefined,
      extra_comment: undefined
    };
  };

  // Copy to clipboard
  const copyToClipboard = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      showSuccess('Copied to clipboard');
    } catch {
      showError('Failed to copy to clipboard');
    }
  };

  // Get full SSH key text
  const getFullKeyText = (key: ExtendedKey) => {
    return `${key.key_type} ${key.key_base64}${key.key_name ? ' ' + key.key_name : ''}`;
  };

  // Handle key creation
  const handleCreateKey = async (formData: Record<string, unknown>) => {
    try {
      setSubmitting(true);

      const keyValidation = validateSSHKey((formData as Record<string, unknown>).keyText as string);
      if (!keyValidation.valid) {
        showError('Invalid SSH Key', keyValidation.message);
        return;
      }

      const keyData = parseSSHKey((formData as Record<string, unknown>).keyText as string);
      if (!keyData) {
        showError('Failed to parse SSH key');
        return;
      }

      const formDataTyped = formData as Record<string, unknown>;
      const keyName = (formDataTyped.key_name as string) || keyData.key_name;
      const extraComment = (formDataTyped.extra_comment as string) || '';
      const keyPayload = {
        user_id: Number(formDataTyped.userId),
        key_type: keyData.key_type,
        key_base64: keyData.key_base64,
        key_name: keyName && keyName.trim() !== '' ? keyName : null,
        extra_comment: extraComment && extraComment.trim() !== '' ? extraComment : null
      };

      const response = await usersService.assignKeyToUser(keyPayload);

      if (response.success) {
        showSuccess('SSH key added successfully');
        setShowAddModal(false);
        loadKeys();
      } else {
        showError('Failed to add SSH key', response.message);
      }
    } catch {
      showError('Failed to add SSH key', 'Please try again');
    } finally {
      setSubmitting(false);
    }
  };

  // Handle key update
  const handleUpdateKey = async (formData: Record<string, unknown>) => {
    if (!selectedKey) return;

    try {
      setSubmitting(true);
      const name = (formData as Record<string, unknown>).name as string;
      const extraComment = (formData as Record<string, unknown>).extra_comment as string;

      // Update both name and extra_comment if provided
      if (name !== undefined) {
        const response = await keysService.updateKeyName(selectedKey.id, name);
        if (!response.success) {
          showError('Failed to update SSH key name', response.message);
          return;
        }
      }

      if (extraComment !== undefined) {
        const response = await keysService.updateKeyExtraComment(selectedKey.id, extraComment);
        if (!response.success) {
          showError('Failed to update SSH key extra comment', response.message);
          return;
        }
      }

      showSuccess('SSH key updated successfully');
      setEditingKeyName(false);
      setEditingExtraComment(false);
      // Update the selected key with new values
      setSelectedKey({
        ...selectedKey,
        key_name: name !== undefined ? name : selectedKey.key_name,
        extra_comment: extraComment !== undefined ? extraComment : selectedKey.extra_comment
      });
      loadKeys();
    } catch {
      showError('Failed to update SSH key', 'Please try again');
    } finally {
      setSubmitting(false);
    }
  };

  // Handle key deletion
  const handleDeleteKey = async () => {
    if (!selectedKey) return;

    try {
      setSubmitting(true);
      const response = await keysService.deleteKey(selectedKey.id);

      if (response.success) {
        showSuccess('SSH key deleted successfully');
        setShowDeleteModal(false);
        setSelectedKey(null);
        loadKeys();
      } else {
        showError('Failed to delete SSH key', response.message);
      }
    } catch {
      showError('Failed to delete SSH key', 'Please try again');
    } finally {
      setSubmitting(false);
    }
  };

  // Handle user updated callback from edit modal
  const handleUserUpdated = () => {
    setEditingUser(null);
    setShowUserEditModal(false);
    // Reload users and keys to get updated data
    loadKeys();
  };

  // Handle bulk assignment
  const handleBulkAssign = async () => {
    try {
      setSubmitting(true);
      // Note: This would need API support for bulk assignment or user reassignment
      // For now, we'll show a message about this functionality
      showError('Bulk assignment not yet supported', 'This feature requires backend API updates');
      setShowBulkAssignModal(false);
    } catch {
      showError('Failed to assign keys', 'Please try again');
    } finally {
      setSubmitting(false);
    }
  };

  // Handle key import
  const handleImportKeys = async (formData: Record<string, unknown>) => {
    try {
      setSubmitting(true);
      const formDataTyped = formData as Record<string, unknown>;
      const keysText = formDataTyped.keysText as string;
      const userId = formDataTyped.userId as number;

      const keyLines = keysText.split('\n').filter(line => line.trim());
      let imported = 0;
      let failed = 0;
      const errors: string[] = [];

      for (const keyLine of keyLines) {
        try {
          const keyValidation = validateSSHKey(keyLine);
          if (!keyValidation.valid) {
            failed++;
            errors.push(`Invalid key format: ${keyValidation.message}`);
            continue;
          }

          const keyData = parseSSHKey(keyLine);
          if (!keyData) {
            failed++;
            errors.push('Failed to parse SSH key');
            continue;
          }

          const keyPayload = {
            user_id: Number(userId),
            key_type: keyData.key_type,
            key_base64: keyData.key_base64,
            key_name: keyData.key_name && keyData.key_name.trim() !== '' ? keyData.key_name : null,
            extra_comment: null
          };

          const response = await usersService.assignKeyToUser(keyPayload);

          if (response.success) {
            imported++;
          } else {
            failed++;
            errors.push(`Failed to import key: ${response.message}`);
          }
        } catch (error) {
          failed++;
          errors.push(`Error importing key: ${error}`);
        }
      }

      if (imported > 0) {
        showSuccess(`${imported} keys imported successfully`);
      }
      if (failed > 0) {
        showError(`${failed} keys failed to import`, errors.slice(0, 3).join(', ') + (errors.length > 3 ? '...' : ''));
      }

      setShowImportModal(false);
      loadKeys();
    } catch {
      showError('Failed to import keys', 'Please try again');
    } finally {
      setSubmitting(false);
    }
  };

  // Filter keys based on current filters and search
  const filteredKeys = useMemo(() => {
    return keys.filter(key => {
      // Search filter
      if (searchTerm.trim()) {
        const lowerSearch = searchTerm.toLowerCase();
        const matchesSearch =
          (key.key_name && key.key_name.toLowerCase().includes(lowerSearch)) ||
          (key.username && key.username.toLowerCase().includes(lowerSearch)) ||
          (key.extra_comment && key.extra_comment.toLowerCase().includes(lowerSearch)) ||
          key.key_type.toLowerCase().includes(lowerSearch);

        if (!matchesSearch) return false;
      }

      // Existing filters
      if (filters.keyType && key.key_type !== filters.keyType) return false;
      if (filters.userId && key.user_id !== filters.userId) return false;
      if (filters.status === 'assigned' && (!key.user_id || key.user_id === 0)) return false;
      if (filters.status === 'unassigned' && key.user_id && key.user_id !== 0) return false;

      return true;
    });
  }, [keys, filters, searchTerm]);

  // Unassigned keys (user_id is 0 or falsy)
  const unassignedKeys = keys.filter(key => !key.user_id || key.user_id === 0);

  // Get status icon and color
  const getStatusIcon = (status: ExtendedKey['status']) => {
    switch (status) {
      case 'deployed':
        return <CheckCircle size={16} className="text-green-600" />;
      case 'pending':
        return <Clock size={16} className="text-yellow-600" />;
      case 'error':
        return <XCircle size={16} className="text-red-600" />;
      default:
        return <AlertCircle size={16} className="text-gray-400" />;
    }
  };

  // Get key type badge color
  const getKeyTypeBadgeColor = (keyType: string) => {
    switch (keyType) {
      case 'ssh-rsa':
        return 'bg-blue-100 text-blue-800 dark:bg-blue-900 dark:text-blue-200';
      case 'ssh-ed25519':
        return 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200';
      case 'ecdsa-sha2-nistp256':
      case 'ecdsa-sha2-nistp384':
      case 'ecdsa-sha2-nistp521':
        return 'bg-purple-100 text-purple-800 dark:bg-purple-900 dark:text-purple-200';
      default:
        return 'bg-gray-100 text-gray-800 dark:bg-gray-700 dark:text-gray-200';
    }
  };

  // Table columns
  const columns: Column<ExtendedKey>[] = [
    {
      key: 'username',
      header: 'User',
      sortable: true,
      searchable: true,
      render: (value: unknown, item: ExtendedKey) => (
        <div className="flex items-center space-x-2">
          {item.user_id && item.user_id !== 0 ? (
            <UserCheck size={16} className="text-green-600" />
          ) : (
            <UserX size={16} className="text-gray-400" />
          )}
          <span className={item.user_id && item.user_id !== 0 ? 'text-gray-900 dark:text-gray-100' : 'text-gray-400'}>
            {(value as string) || 'Unassigned'}
          </span>
          {item.user_id && item.user_id !== 0 && (
            <Button
              variant="ghost"
              size="sm"
              onClick={async (e) => {
                e.stopPropagation();
                const user = users.find(u => u.id === item.user_id);
                if (user) {
                  setEditingUser(user);
                  setShowUserEditModal(true);
                } else {
                  showError('User not found', 'Unable to load user details');
                }
              }}
              title="Edit user"
              className="p-1 h-auto hover:bg-gray-100 dark:hover:bg-gray-700"
            >
              <Edit2 size={14} className="text-gray-400 hover:text-gray-600 dark:text-gray-500 dark:hover:text-gray-300" />
            </Button>
          )}
        </div>
      ),
    },
    {
      key: 'key_name',
      header: 'Key Name',
      searchable: true,
      render: (value: unknown, key: ExtendedKey) => (
        <div className="text-gray-600 dark:text-gray-400 max-w-xs">
          <div className="truncate">
            <span className="font-medium">Name:</span> {(value as string) || '—'}
          </div>
          {key.extra_comment && (
            <div className="truncate text-xs mt-1">
              <span className="font-medium">Comment:</span> {key.extra_comment}
            </div>
          )}
        </div>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      sortable: true,
      width: '100px',
      render: (value: unknown) => (
        <div className="flex items-center space-x-2">
          {getStatusIcon(value as ExtendedKey['status'])}
          <span className="text-sm capitalize">{value as string}</span>
        </div>
      ),
    },
    {
      key: 'hostCount',
      header: 'Hosts',
      sortable: true,
      width: '80px',
      render: (value: unknown) => (
        <div className="flex items-center space-x-1">
          <Shield size={14} className="text-gray-400" />
          <span>{(value as number) || 0}</span>
        </div>
      ),
    },
    {
      key: 'actions',
      header: 'Actions',
      width: '200px',
      render: (_, item: ExtendedKey) => (
        <div className="flex items-center justify-end space-x-2">
          <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${getKeyTypeBadgeColor(item.key_type)}`}>
            {item.key_type.replace('ssh-', '').toUpperCase()}
          </span>
          <Button
            variant="ghost"
            size="sm"
            onClick={(e) => {
              e.stopPropagation();
              setSelectedKey(item);
              setKeyNameValue(item.key_name || '');
              setExtraCommentValue(item.extra_comment || '');
              setEditingKeyName(false);
              setEditingExtraComment(false);
              setShowViewModal(true);
            }}
            title="View/Edit key"
          >
            <Edit2 size={16} />
          </Button>
          {(!item.user_id || item.user_id === 0) && (
            <Button
              variant="ghost"
              size="sm"
              onClick={(e) => {
                e.stopPropagation();
                setSelectedKey(item);
                setShowAssignModal(true);
              }}
              title="Assign to user"
            >
              <UserPlus size={16} />
            </Button>
          )}
          <Button
            variant="ghost"
            size="sm"
            onClick={(e) => {
              e.stopPropagation();
              setSelectedKey(item);
              setShowDeleteModal(true);
            }}
            title="Delete key"
            className="text-red-600 hover:text-red-800"
          >
            <Trash2 size={16} />
          </Button>
        </div>
      ),
    },
  ];

  // Form fields for add key modal
  const addKeyFields: FormField[] = [
    {
      name: 'userId',
      label: 'Assign to User',
      type: 'select',
      required: true,
      options: [
        { value: '', label: 'Select a user' },
        ...users.map(user => ({
          value: user.id,
          label: user.username,
          disabled: !user.enabled
        }))
      ],
    },
    {
      name: 'keyText',
      label: 'SSH Key',
      type: 'textarea',
      required: true,
      rows: 4,
      placeholder: 'Paste your SSH public key here (e.g., ssh-rsa AAAA... user@host)',
      helperText: 'Paste the complete SSH public key including type, key data, and optional comment',
      validation: {
        custom: (value: unknown) => {
          const validation = validateSSHKey(value as string);
          return validation.valid ? null : validation.message || 'Invalid SSH key format';
        }
      }
    },
    {
      name: 'key_name',
      label: 'Key Name (Optional)',
      type: 'text',
      placeholder: 'Optional name for this key',
      helperText: 'Leave empty to use the name from the key itself',
    },
    {
      name: 'extra_comment',
      label: 'Extra Comment (Optional)',
      type: 'text',
      placeholder: 'Additional notes about this key',
      helperText: 'Additional comments or notes about this SSH key',
    },
  ];


  // Form fields for assign modal  
  const assignKeyFields: FormField[] = [
    {
      name: 'userId',
      label: 'Assign to User',
      type: 'select',
      required: true,
      options: users.map(user => ({
        value: user.id,
        label: user.username,
        disabled: !user.enabled
      })),
    },
  ];

  // Form fields for bulk assign modal
  const bulkAssignFields: FormField[] = [
    {
      name: 'userId',
      label: 'Assign Selected Keys to User',
      type: 'select',
      required: true,
      options: users.map(user => ({
        value: user.id,
        label: user.username,
        disabled: !user.enabled
      })),
    },
  ];

  // Form fields for import modal
  const importKeyFields: FormField[] = [
    {
      name: 'userId',
      label: 'Import Keys for User',
      type: 'select',
      required: true,
      options: users.map(user => ({
        value: user.id,
        label: user.username,
        disabled: !user.enabled
      })),
    },
    {
      name: 'keysText',
      label: 'SSH Keys',
      type: 'textarea',
      required: true,
      rows: 8,
      placeholder: 'Paste multiple SSH public keys, one per line',
      helperText: 'Each line should contain a complete SSH public key',
    },
  ];

  return (
    <div className="space-y-6 animate-in fade-in duration-500">
      {/* Header with Glassmorphism */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4 p-6 rounded-2xl bg-card/30 backdrop-blur-xl border border-white/10 shadow-lg">
        <div>
          <h1 className="text-3xl font-bold tracking-tight text-foreground flex items-center gap-3">
            <div className="p-2 bg-primary/10 rounded-lg text-primary">
              <Key size={24} />
            </div>
            SSH Keys
          </h1>
          <p className="text-muted-foreground mt-1 ml-14">
            Manage SSH public keys for users and assignments
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-3">
          {/* Search Input */}
          <div className="w-full md:w-64">
            <Input
              placeholder="Search keys..."
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              leftIcon={<Search size={16} />}
              className="h-10 bg-background/50 border-border focus:bg-background transition-colors"
            />
          </div>

          {/* View Toggle */}
          <div className="flex items-center bg-secondary/50 p-1 rounded-lg border border-border">
            <button
              onClick={() => setViewMode('list')}
              className={cn(
                "p-2 rounded-md transition-all duration-200",
                viewMode === 'list' ? "bg-background shadow-sm text-foreground" : "text-muted-foreground hover:text-foreground"
              )}
              title="List View"
            >
              <List size={18} />
            </button>
            <button
              onClick={() => setViewMode('grid')}
              className={cn(
                "p-2 rounded-md transition-all duration-200",
                viewMode === 'grid' ? "bg-background shadow-sm text-foreground" : "text-muted-foreground hover:text-foreground"
              )}
              title="Grid View"
            >
              <LayoutGrid size={18} />
            </button>
          </div>

          <Button
            variant="secondary"
            onClick={() => setShowImportModal(true)}
            leftIcon={<Upload size={16} />}
            className="h-10"
          >
            Import
          </Button>
          <Button
            onClick={() => setShowAddModal(true)}
            className="shadow-lg shadow-primary/20 h-10"
          >
            <Plus size={18} className="mr-2" />
            Add Key
          </Button>
        </div>
      </div>

      {/* Stats Bar */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div className="p-4 rounded-xl bg-gradient-to-br from-blue-500/10 to-blue-600/5 border border-blue-500/20">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm text-muted-foreground">Total Keys</p>
              <p className="text-2xl font-bold text-foreground">{keys.length}</p>
            </div>
            <Key size={24} className="text-blue-500" />
          </div>
        </div>

        <div className="p-4 rounded-xl bg-gradient-to-br from-green-500/10 to-green-600/5 border border-green-500/20">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm text-muted-foreground">Assigned</p>
              <p className="text-2xl font-bold text-foreground">{keys.filter(k => k.user_id && k.user_id !== 0).length}</p>
            </div>
            <UserCheck size={24} className="text-green-500" />
          </div>
        </div>

        <div className="p-4 rounded-xl bg-gradient-to-br from-purple-500/10 to-purple-600/5 border border-purple-500/20">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm text-muted-foreground">Active Users</p>
              <p className="text-2xl font-bold text-foreground">{users.filter(u => u.enabled).length}</p>
            </div>
            <Users size={24} className="text-purple-500" />
          </div>
        </div>

        <div className="p-4 rounded-xl bg-gradient-to-br from-yellow-500/10 to-yellow-600/5 border border-yellow-500/20">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm text-muted-foreground">Unassigned</p>
              <p className="text-2xl font-bold text-foreground">{unassignedKeys.length}</p>
            </div>
            <UserX size={24} className="text-yellow-500" />
          </div>
        </div>
      </div>

      {/* Filters */}
      <div className="flex flex-wrap gap-2">
        <Button
          variant={filters.keyType === undefined ? "primary" : "ghost"}
          size="sm"
          onClick={() => setFilters({ ...filters, keyType: undefined })}
          className="rounded-full"
        >
          All Types
        </Button>
        {['ssh-rsa', 'ssh-ed25519', 'ecdsa-sha2-nistp256'].map(type => (
          <Button
            key={type}
            variant={filters.keyType === type ? "primary" : "ghost"}
            size="sm"
            onClick={() => setFilters({ ...filters, keyType: type })}
            className="rounded-full text-xs"
          >
            {type.replace('ssh-', '').toUpperCase()}
          </Button>
        ))}
        <div className="ml-auto flex gap-2">
          <Button
            variant={filters.status === 'assigned' ? "primary" : "ghost"}
            size="sm"
            onClick={() => setFilters({ ...filters, status: filters.status === 'assigned' ? undefined : 'assigned' })}
            className="rounded-full"
          >
            <UserCheck size={14} className="mr-1" />
            Assigned
          </Button>
          <Button
            variant={filters.status === 'unassigned' ? "primary" : "ghost"}
            size="sm"
            onClick={() => setFilters({ ...filters, status: filters.status === 'unassigned' ? undefined : 'unassigned' })}
            className="rounded-full"
          >
            <UserX size={14} className="mr-1" />
            Unassigned
          </Button>
        </div>
      </div>

      {/* Content */}
      {viewMode === 'grid' ? (
        <KeyGrid
          keys={filteredKeys}
          onEdit={(key) => {
            setSelectedKey(key);
            setKeyNameValue(key.key_name || '');
            setExtraCommentValue(key.extra_comment || '');
            setEditingKeyName(false);
            setEditingExtraComment(false);
            setShowViewModal(true);
          }}
          onDelete={(key) => {
            setSelectedKey(key);
            setShowDeleteModal(true);
          }}
          onAssign={(key) => {
            setSelectedKey(key);
            setShowAssignModal(true);
          }}
        />
      ) : (
        <Card className="border-border/50 bg-card/50 backdrop-blur-sm overflow-hidden shadow-xl">
          <CardContent className="p-0">
            <DataTable
              data={filteredKeys}
              columns={columns}
              loading={loading}
              searchable={false}
              emptyMessage={
                searchTerm ? `No keys found matching "${searchTerm}"` :
                  "No SSH keys found. Add your first key to get started."
              }
              initialSort={{ key: 'username', direction: 'asc' }}
            />
          </CardContent>
        </Card>
      )}

      {/* Add Key Modal */}
      <Modal
        isOpen={showAddModal}
        onClose={() => setShowAddModal(false)}
        title="Add SSH Key"
        size="lg"
      >
        <Form
          fields={addKeyFields}
          onSubmit={handleCreateKey}
          loading={submitting}
          submitText="Add SSH Key"
          onCancel={() => setShowAddModal(false)}
        />
      </Modal>


      {/* Delete Key Modal */}
      <Modal
        isOpen={showDeleteModal}
        onClose={() => setShowDeleteModal(false)}
        title="Delete SSH Key"
        size="md"
      >
        <div className="space-y-4">
          <div className="flex items-start space-x-3">
            <AlertCircle className="text-red-600 mt-0.5" size={20} />
            <div>
              <h3 className="font-medium text-gray-900 dark:text-gray-100">
                Are you sure you want to delete this SSH key?
              </h3>
              <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                This action cannot be undone. The key will be removed from all authorized_keys files.
              </p>
            </div>
          </div>

          {selectedKey && (
            <div className="bg-gray-50 dark:bg-gray-800 rounded-lg p-4">
              <div className="space-y-2">
                <div className="flex justify-between">
                  <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Key Type:</span>
                  <span className="text-sm text-gray-900 dark:text-gray-100">{selectedKey.key_type.replace('ssh-', '').toUpperCase()}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-sm font-medium text-gray-700 dark:text-gray-300">User:</span>
                  <span className="text-sm text-gray-900 dark:text-gray-100">{selectedKey.username || 'Unassigned'}</span>
                </div>
                <div className="flex justify-between">
                  <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Key Name:</span>
                  <span className="text-sm text-gray-900 dark:text-gray-100">{selectedKey.key_name || '—'}</span>
                </div>
                {selectedKey.extra_comment && (
                  <div className="flex justify-between">
                    <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Extra Comment:</span>
                    <span className="text-sm text-gray-900 dark:text-gray-100">{selectedKey.extra_comment}</span>
                  </div>
                )}
                <div className="flex justify-between">
                  <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Host Access:</span>
                  <span className="text-sm text-gray-900 dark:text-gray-100">{selectedKey.hostCount || 0} hosts</span>
                </div>
              </div>
            </div>
          )}

          <div className="flex items-center justify-end space-x-3">
            <Button
              variant="secondary"
              onClick={() => setShowDeleteModal(false)}
              disabled={submitting}
            >
              Cancel
            </Button>
            <Button
              variant="primary"
              onClick={handleDeleteKey}
              loading={submitting}
              className="bg-red-600 hover:bg-red-700 text-white"
              leftIcon={<Trash2 size={16} />}
            >
              Delete Key
            </Button>
          </div>
        </div>
      </Modal>

      {/* View/Edit Key Modal */}
      <Modal
        isOpen={showViewModal}
        onClose={() => {
          setShowViewModal(false);
          setEditingKeyName(false);
          setEditingExtraComment(false);
          setKeyNameValue('');
          setExtraCommentValue('');
        }}
        title="SSH Key Details"
        size="xl"
      >
        {selectedKey && (
          <div className="space-y-6">
            {/* Key Information */}
            <div className="space-y-4">
              <h3 className="text-lg font-medium text-gray-900 dark:text-gray-100">Key Information</h3>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="text-sm font-medium text-gray-700 dark:text-gray-300">Key Type</label>
                  <p className="mt-1 text-gray-900 dark:text-gray-100">{selectedKey.key_type}</p>
                </div>
                <div>
                  <label className="text-sm font-medium text-gray-700 dark:text-gray-300">Status</label>
                  <div className="mt-1 flex items-center space-x-2">
                    {getStatusIcon(selectedKey.status)}
                    <span className="capitalize text-gray-900 dark:text-gray-100">{selectedKey.status}</span>
                  </div>
                </div>
                <div>
                  <label className="text-sm font-medium text-gray-700 dark:text-gray-300">Assigned User</label>
                  <p className="mt-1 text-gray-900 dark:text-gray-100">{selectedKey.username || 'Unassigned'}</p>
                </div>
                <div>
                  <label className="text-sm font-medium text-gray-700 dark:text-gray-300">Host Access</label>
                  <p className="mt-1 text-gray-900 dark:text-gray-100">{selectedKey.hostCount || 0} hosts</p>
                </div>
                <div className="col-span-2 space-y-4">
                  {/* Key Name */}
                  <div>
                    <div className="flex items-center justify-between">
                      <label className="text-sm font-medium text-gray-700 dark:text-gray-300">Key Name</label>
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => {
                          if (editingKeyName) {
                            handleUpdateKey({ name: keyNameValue });
                            setEditingKeyName(false);
                          } else {
                            setKeyNameValue(selectedKey.key_name || '');
                            setEditingKeyName(true);
                          }
                        }}
                        leftIcon={editingKeyName ? <CheckCircle size={16} /> : <Edit2 size={16} />}
                        disabled={submitting}
                      >
                        {editingKeyName ? 'Save' : 'Edit'}
                      </Button>
                    </div>
                    {editingKeyName ? (
                      <div className="mt-2 space-y-2">
                        <input
                          type="text"
                          value={keyNameValue}
                          onChange={(e) => setKeyNameValue(e.target.value)}
                          placeholder="Enter key name"
                          className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 focus:outline-none focus:ring-2 focus:ring-blue-500"
                          disabled={submitting}
                          autoFocus
                        />
                        <div className="flex items-center space-x-2">
                          <Button
                            variant="secondary"
                            size="sm"
                            onClick={() => {
                              setEditingKeyName(false);
                              setKeyNameValue(selectedKey.key_name || '');
                            }}
                            disabled={submitting}
                          >
                            Cancel
                          </Button>
                        </div>
                      </div>
                    ) : (
                      <p className="mt-1 text-gray-900 dark:text-gray-100">{selectedKey.key_name || 'No name'}</p>
                    )}
                  </div>

                  {/* Extra Comment */}
                  <div>
                    <div className="flex items-center justify-between">
                      <label className="text-sm font-medium text-gray-700 dark:text-gray-300">Extra Comment</label>
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => {
                          if (editingExtraComment) {
                            handleUpdateKey({ extra_comment: extraCommentValue });
                            setEditingExtraComment(false);
                          } else {
                            setExtraCommentValue(selectedKey.extra_comment || '');
                            setEditingExtraComment(true);
                          }
                        }}
                        leftIcon={editingExtraComment ? <CheckCircle size={16} /> : <Edit2 size={16} />}
                        disabled={submitting}
                      >
                        {editingExtraComment ? 'Save' : 'Edit'}
                      </Button>
                    </div>
                    {editingExtraComment ? (
                      <div className="mt-2 space-y-2">
                        <input
                          type="text"
                          value={extraCommentValue}
                          onChange={(e) => setExtraCommentValue(e.target.value)}
                          placeholder="Enter additional comment"
                          className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-800 text-gray-900 dark:text-gray-100 focus:outline-none focus:ring-2 focus:ring-blue-500"
                          disabled={submitting}
                          autoFocus
                        />
                        <div className="flex items-center space-x-2">
                          <Button
                            variant="secondary"
                            size="sm"
                            onClick={() => {
                              setEditingExtraComment(false);
                              setExtraCommentValue(selectedKey.extra_comment || '');
                            }}
                            disabled={submitting}
                          >
                            Cancel
                          </Button>
                        </div>
                      </div>
                    ) : (
                      <p className="mt-1 text-gray-900 dark:text-gray-100">{selectedKey.extra_comment || 'No extra comment'}</p>
                    )}
                  </div>
                </div>
              </div>
            </div>

            {/* Full Key */}
            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <label className="text-sm font-medium text-gray-700 dark:text-gray-300">Full SSH Key</label>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => copyToClipboard(getFullKeyText(selectedKey))}
                  leftIcon={<Copy size={16} />}
                >
                  Copy Key
                </Button>
              </div>
              <div className="bg-gray-50 dark:bg-gray-800 rounded-lg p-4">
                <code className="text-xs font-mono break-all text-gray-900 dark:text-gray-100">
                  {getFullKeyText(selectedKey)}
                </code>
              </div>
            </div>

            {/* Key Details */}
            {loadingDetails ? (
              <div className="flex items-center justify-center py-8">
                <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
              </div>
            ) : keyDetails && (
              <div className="space-y-4">
                <h3 className="text-lg font-medium text-gray-900 dark:text-gray-100">Access Details</h3>
                <div className="bg-gray-50 dark:bg-gray-800 rounded-lg p-4">
                  <p className="text-sm text-gray-600 dark:text-gray-400">
                    This key provides access to {keyDetails.authorizations.length} host authorizations.
                  </p>
                </div>
              </div>
            )}
          </div>
        )}
      </Modal>

      {/* Assign Key Modal */}
      <Modal
        isOpen={showAssignModal}
        onClose={() => setShowAssignModal(false)}
        title="Assign SSH Key"
        size="md"
      >
        <Form
          fields={assignKeyFields}
          onSubmit={async () => {
            if (!selectedKey) return;
            try {
              setSubmitting(true);
              // Note: This would need API support for user reassignment
              // For now, showing a message about this functionality
              showError('Key reassignment not yet supported', 'This feature requires backend API updates');
              setShowAssignModal(false);
              setSelectedKey(null);
            } catch {
              showError('Failed to assign SSH key', 'Please try again');
            } finally {
              setSubmitting(false);
            }
          }}
          loading={submitting}
          submitText="Assign Key"
          onCancel={() => setShowAssignModal(false)}
        />
      </Modal>

      {/* Bulk Assign Modal */}
      <Modal
        isOpen={showBulkAssignModal}
        onClose={() => setShowBulkAssignModal(false)}
        title="Bulk Assign SSH Keys"
        size="md"
      >
        <div className="space-y-4">
          <div className="bg-blue-50 dark:bg-blue-900/20 rounded-lg p-4">
            <p className="text-sm text-blue-700 dark:text-blue-300">
              You are about to assign {selectedKeys.length} SSH keys to a user.
            </p>
          </div>
          <Form
            fields={bulkAssignFields}
            onSubmit={handleBulkAssign}
            loading={submitting}
            submitText={`Assign ${selectedKeys.length} Keys`}
            onCancel={() => setShowBulkAssignModal(false)}
          />
        </div>
      </Modal>

      {/* Import Keys Modal */}
      <Modal
        isOpen={showImportModal}
        onClose={() => setShowImportModal(false)}
        title="Import SSH Keys"
        size="lg"
      >
        <div className="space-y-4">
          <div className="bg-blue-50 dark:bg-blue-900/20 rounded-lg p-4">
            <h4 className="font-medium text-blue-900 dark:text-blue-100">Import Instructions</h4>
            <ul className="mt-2 text-sm text-blue-700 dark:text-blue-300 list-disc list-inside space-y-1">
              <li>Paste one SSH public key per line</li>
              <li>Each key should include type, key data, and optional comment</li>
              <li>Invalid keys will be skipped with error details</li>
              <li>All valid keys will be assigned to the selected user</li>
            </ul>
          </div>
          <Form
            fields={importKeyFields}
            onSubmit={handleImportKeys}
            loading={submitting}
            submitText="Import Keys"
            onCancel={() => setShowImportModal(false)}
          />
        </div>
      </Modal>

      {/* Edit User Modal */}
      <UserEditModal
        isOpen={showUserEditModal}
        onClose={() => {
          setShowUserEditModal(false);
          setEditingUser(null);
        }}
        user={editingUser}
        onUserUpdated={handleUserUpdated}
        users={users}
      />
    </div >
  );
};

export default KeysPage;