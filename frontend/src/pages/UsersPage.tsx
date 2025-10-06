import React, { useState, useEffect, useCallback } from 'react';
import { useLocation } from 'react-router-dom';
import {
  Users,
  Plus,
  Edit2,
  Trash2,
  Key,
  Shield,
  AlertCircle,
  CheckCircle,
  XCircle,
  UserPlus,
  UserMinus,
  Split
} from 'lucide-react';
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Button,
  DataTable,
  Modal,
  Form,
  type Column,
  type FormField
} from '../components/ui';
import { useNotifications } from '../contexts/NotificationContext';
import { usersService } from '../services/api/users';
import { keysService } from '../services/api/keys';
import { authorizationsService } from '../services/api/authorizations';
import { hostsService } from '../services/api/hosts';
import UserEditModal from '../components/UserEditModal';
import SplitKeysModal from '../components/SplitKeysModal';
import type {
  User,
  PublicUserKey,
  Authorization,
  RawAuthorizationResponse,
  Host
} from '../types';

interface ExtendedUser extends User {
  keyCount?: number;
  authorizationCount?: number;
  lastActive?: Date;
  [key: string]: unknown;
}

interface UserDetailsData {
  keys: PublicUserKey[];
  authorizations: Authorization[];
  hosts: Host[];
}

const UsersPage: React.FC = () => {
  const location = useLocation();
  const { showSuccess, showError } = useNotifications();
  
  
  // State management
  const [users, setUsers] = useState<ExtendedUser[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedUser, setSelectedUser] = useState<ExtendedUser | null>(null);
  const [userDetails, setUserDetails] = useState<UserDetailsData | null>(null);
  
  // Modal states
  const [showAddModal, setShowAddModal] = useState(false);
  const [showEditModal, setShowEditModal] = useState(false);
  const [showDeleteModal, setShowDeleteModal] = useState(false);
  const [showKeysModal, setShowKeysModal] = useState(false);
  const [showAuthorizationsModal, setShowAuthorizationsModal] = useState(false);
  const [showSplitKeysModal, setShowSplitKeysModal] = useState(false);
  
  // Form loading states
  const [submitting, setSubmitting] = useState(false);
  const [loadingDetails, setLoadingDetails] = useState(false);

  // Load users with extended information
  const loadUsers = useCallback(async () => {
    try {
      setLoading(true);
      const response = await usersService.getUsers();
      if (response.success && response.data) {
        // Load additional data for each user
        const usersWithDetails = await Promise.all(
          response.data.items.map(async (user) => {
            try {
              const [keysResponse, authResponse] = await Promise.all([
                keysService.getKeysForUser(user.username),
                authorizationsService.getUserAuthorizations(user.username)
              ]);
              
              return {
                ...user,
                keyCount: keysResponse.success ? keysResponse.data?.length || 0 : 0,
                authorizationCount: authResponse.success ? authResponse.data?.length || 0 : 0
              };
            } catch {
              return {
                ...user,
                keyCount: 0,
                authorizationCount: 0
              };
            }
          })
        );
        
        setUsers(usersWithDetails);
      }
    } catch {
      showError('Failed to load users', 'Please try again later');
    } finally {
      setLoading(false);
    }
  }, [showError]);

  useEffect(() => {
    loadUsers();
  }, [loadUsers]);

  // Load detailed user information
  const loadUserDetails = useCallback(async (user: ExtendedUser) => {
    try {
      setLoadingDetails(true);
      const [keysResponse, authResponse, hostsResponse] = await Promise.all([
        keysService.getKeysForUser(user.username),
        authorizationsService.getUserAuthorizations(user.username),
        hostsService.getAllHosts()
      ]);

      // Create host name to ID mapping
      const hosts = hostsResponse.success ? hostsResponse.data || [] : [];
      const hostNameToId = new Map(hosts.map(h => [h.name, h.id]));

      // Map raw authorizations to proper Authorization objects with host_id
      const rawAuths = (authResponse.success ? authResponse.data || [] : []) as unknown as RawAuthorizationResponse[];
      const mappedAuthorizations = rawAuths.map((auth) => ({
        id: auth.id,
        user_id: user.id, // Current user's ID
        host_id: hostNameToId.get(auth.username) || 0, // auth.username is actually hostname
        login: auth.login,
        options: auth.options,
        comment: auth.comment
      }));

      setUserDetails({
        keys: keysResponse.success ? keysResponse.data || [] : [],
        authorizations: mappedAuthorizations,
        hosts: hosts
      });
    } catch {
      showError('Failed to load user details', 'Please try again later');
    } finally {
      setLoadingDetails(false);
    }
  }, [showError]);

  // Form field definitions for add user modal
  const getFormFields = (): FormField[] => [
    {
      name: 'username',
      label: 'Username',
      type: 'text',
      required: true,
      placeholder: 'Enter username',
      helperText: 'Unique username for SSH access',
      validation: {
        minLength: 2,
        maxLength: 50,
        pattern: /^[a-zA-Z0-9\-_.\s@]+$/,
        custom: (value: unknown) => {
          const exists = users.some(u => u.username.toLowerCase() === (value as string).toLowerCase());
          return exists ? 'Username already exists' : null;
        }
      }
    },
    {
      name: 'enabled',
      label: 'User Status',
      type: 'select',
      required: true,
      placeholder: 'Select user status',
      helperText: 'Whether the user account is active',
      options: [
        { value: 'true', label: 'Enabled (Active)' },
        { value: 'false', label: 'Disabled (Inactive)' }
      ]
    },
    {
      name: 'comment',
      label: 'Comment',
      type: 'text',
      placeholder: 'Optional comment about this user',
      helperText: 'Add any notes or comments about this user'
    }
  ];

  // Handle form submissions
  const handleAddUser = async (values: Record<string, unknown>) => {
    try {
      setSubmitting(true);
      const valuesTyped = values as Record<string, unknown>;
      const userData = {
        username: valuesTyped.username as string,
        enabled: valuesTyped.enabled === 'true',
        comment: valuesTyped.comment && (valuesTyped.comment as string).trim() !== '' ? (valuesTyped.comment as string).trim() : undefined
      };

      const response = await usersService.createUser(userData);
      if (response.success && response.data) {
        await loadUsers(); // Reload to get updated counts
        setShowAddModal(false);
        showSuccess('User added', `${response.data.username} has been added successfully`);
      }
    } catch {
      showError('Failed to add user', 'Please check your input and try again');
    } finally {
      setSubmitting(false);
    }
  };

  // Handle user updated callback from edit modal
  const handleUserUpdated = () => {
    setSelectedUser(null);
    setShowEditModal(false);
    // Reload users to get updated data with fresh counts
    loadUsers();
  };

  const handleDeleteUser = async () => {
    if (!selectedUser) return;

    try {
      setSubmitting(true);
      const response = await usersService.deleteUser(selectedUser.username);
      if (response.success) {
        setUsers(prev => prev.filter(u => u.id !== selectedUser.id));
        setShowDeleteModal(false);
        setSelectedUser(null);
        showSuccess('User deleted', `${selectedUser.username} has been deleted successfully`);
      }
    } catch {
      showError('Failed to delete user', 'Please try again later');
    } finally {
      setSubmitting(false);
    }
  };

  const handleToggleUser = async (user: ExtendedUser) => {
    try {
      const response = await usersService.toggleUser(user.id, !user.enabled);
      if (response.success && response.data) {
        setUsers(prev => prev.map(u => 
          u.id === user.id ? { ...u, enabled: response.data!.enabled } : u
        ));
        showSuccess(
          `User ${response.data.enabled ? 'enabled' : 'disabled'}`,
          `${user.username} has been ${response.data.enabled ? 'enabled' : 'disabled'}`
        );
      }
    } catch {
      showError('Failed to toggle user status', 'Please try again later');
    }
  };

  const handleViewKeys = async (user: ExtendedUser) => {
    setSelectedUser(user);
    await loadUserDetails(user);
    setShowKeysModal(true);
  };

  const handleViewAuthorizations = async (user: ExtendedUser) => {
    setSelectedUser(user);
    await loadUserDetails(user);
    setShowAuthorizationsModal(true);
  };

  // Table column definitions
  const columns: Column<ExtendedUser>[] = [
    {
      key: 'username',
      header: 'Username',
      sortable: true,
      render: (value, user) => (
        <div className="flex items-center space-x-2">
          <button
            className="font-medium text-gray-900 dark:text-gray-100 hover:text-blue-600 dark:hover:text-blue-400 text-left cursor-pointer"
            onClick={(e) => {
              e.stopPropagation();
              setSelectedUser(user);
              setShowEditModal(true);
            }}
            title="Click to edit user"
          >
            {value as string}
          </button>
          {!(user as ExtendedUser).enabled && (
            <XCircle size={14} className="text-red-500" />
          )}
        </div>
      )
    },
    {
      key: 'comment',
      header: 'Comment',
      render: (comment) => (
        <div className="text-sm text-gray-600 dark:text-gray-400 max-w-48 truncate" title={(comment as string) || ''}>
          {(comment as string) || '—'}
        </div>
      )
    },
    {
      key: 'enabled',
      header: 'Status',
      sortable: true,
      render: (enabled) => {
        const status = enabled ? 'enabled' : 'disabled';
        const colors = {
          enabled: 'text-green-700 bg-green-50 dark:text-green-400 dark:bg-green-900/20',
          disabled: 'text-red-700 bg-red-50 dark:text-red-400 dark:bg-red-900/20'
        };
        const icons = {
          enabled: <CheckCircle size={14} />,
          disabled: <XCircle size={14} />
        };

        return (
          <div className={`inline-flex items-center space-x-1 px-2 py-1 rounded-full text-xs font-medium ${colors[status]}`}>
            {icons[status]}
            <span className="capitalize">{status}</span>
          </div>
        );
      }
    },
    {
      key: 'keyCount',
      header: 'SSH Keys',
      sortable: true,
      render: (count, user) => (
        <div className="flex items-center space-x-2">
          <Key size={14} className="text-gray-400" />
          <span className="text-sm font-medium">
            {(count as number) || 0}
          </span>
          {((count as number) || 0) > 0 && (
            <Button
              variant="ghost"
              size="sm"
              onClick={(e) => {
                e.stopPropagation();
                handleViewKeys(user);
              }}
              className="text-xs"
            >
              View
            </Button>
          )}
        </div>
      )
    },
    {
      key: 'authorizationCount',
      header: 'Access',
      sortable: true,
      render: (count, user) => (
        <div className="flex items-center space-x-2">
          <Shield size={14} className="text-gray-400" />
          <span className="text-sm font-medium">
            {(count as number) || 0} hosts
          </span>
          {((count as number) || 0) > 0 && (
            <Button
              variant="ghost"
              size="sm"
              onClick={(e) => {
                e.stopPropagation();
                handleViewAuthorizations(user);
              }}
              className="text-xs"
            >
              View
            </Button>
          )}
        </div>
      )
    },
    {
      key: 'id',
      header: 'User ID',
      sortable: true,
      render: (id) => (
        <code className="text-xs bg-gray-100 dark:bg-gray-800 px-2 py-1 rounded">
          #{id as number}
        </code>
      )
    },
    {
      key: 'actions',
      header: 'Actions',
      render: (_, user) => (
        <div className="flex items-center space-x-2">
          <Button
            variant="ghost"
            size="sm"
            onClick={(e) => {
              e.stopPropagation();
              handleToggleUser(user);
            }}
            title={user.enabled ? 'Disable user' : 'Enable user'}
          >
            {user.enabled ? <UserMinus size={16} /> : <UserPlus size={16} />}
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={(e) => {
              e.stopPropagation();
              setSelectedUser(user);
              setShowEditModal(true);
            }}
            title="Edit user"
          >
            <Edit2 size={16} />
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={(e) => {
              e.stopPropagation();
              setSelectedUser(user);
              setShowDeleteModal(true);
            }}
            title="Delete user"
          >
            <Trash2 size={16} />
          </Button>
          {(user as ExtendedUser).keyCount! > 1 && (
            <Button
              variant="ghost"
              size="sm"
              onClick={async (e) => {
                e.stopPropagation();
                setSelectedUser(user);
                await loadUserDetails(user);
                setShowSplitKeysModal(true);
              }}
              title="Split keys to new user"
            >
              <Split size={16} />
            </Button>
          )}
        </div>
      )
    }
  ];

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white flex items-center space-x-2">
            <Users size={24} />
            <span>Users</span>
          </h1>
          <p className="text-gray-600 dark:text-gray-400">
            Manage users and their SSH access permissions
          </p>
        </div>
        <Button onClick={() => setShowAddModal(true)} leftIcon={<Plus size={16} />}>
          Add User
        </Button>
      </div>

      {/* User List */}
      <Card>
        <CardHeader>
          <CardTitle>SSH Users ({users.length})</CardTitle>
        </CardHeader>
        <CardContent>
          <DataTable
            data={users}
            columns={columns}
            loading={loading}
            emptyMessage="No users found. Add your first user to get started."
            searchPlaceholder="Search users by username..."
            initialSort={{ key: 'username', direction: 'asc' }}
            initialSearch={(location.state as { searchTerm?: string })?.searchTerm || ''}
          />
        </CardContent>
      </Card>

      {/* Add User Modal */}
      <Modal
        isOpen={showAddModal}
        onClose={() => setShowAddModal(false)}
        title="Add New User"
        size="md"
      >
        <Form
          fields={getFormFields()}
          onSubmit={(values) => handleAddUser(values)}
          submitText="Add User"
          cancelText="Cancel"
          onCancel={() => setShowAddModal(false)}
          loading={submitting}
          initialValues={{
            enabled: true
          }}
        />
      </Modal>

      {/* Edit User Modal */}
      <UserEditModal
        isOpen={showEditModal}
        onClose={() => {
          setShowEditModal(false);
          setSelectedUser(null);
        }}
        user={selectedUser}
        onUserUpdated={handleUserUpdated}
        users={users}
      />

      {/* Delete Confirmation Modal */}
      <Modal
        isOpen={showDeleteModal}
        onClose={() => {
          setShowDeleteModal(false);
          setSelectedUser(null);
        }}
        title="Delete User"
        size="md"
      >
        {selectedUser && (
          <div className="space-y-4">
            <div className="flex items-start space-x-3">
              <AlertCircle className="text-red-500 mt-1" size={20} />
              <div>
                <p className="text-gray-900 dark:text-gray-100">
                  Are you sure you want to delete user <strong>{selectedUser.username}</strong>?
                </p>
                <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                  This action cannot be undone. All SSH keys and host authorizations for this user will be permanently removed.
                </p>
              </div>
            </div>
            
            <div className="bg-gray-50 dark:bg-gray-800 p-3 rounded-md">
              <div className="text-sm space-y-1">
                <div><strong>Username:</strong> {selectedUser.username}</div>
                <div><strong>Status:</strong> {selectedUser.enabled ? 'Enabled' : 'Disabled'}</div>
                <div><strong>SSH Keys:</strong> {selectedUser.keyCount || 0}</div>
                <div><strong>Host Access:</strong> {selectedUser.authorizationCount || 0} hosts</div>
              </div>
            </div>

            {(selectedUser.keyCount! > 0 || selectedUser.authorizationCount! > 0) && (
              <div className="bg-yellow-50 dark:bg-yellow-900/20 p-3 rounded-md">
                <div className="flex items-start space-x-2">
                  <AlertCircle className="text-yellow-600 dark:text-yellow-400 mt-1" size={16} />
                  <div className="text-sm text-yellow-800 dark:text-yellow-200">
                    <p className="font-medium">Impact of deletion:</p>
                    <ul className="mt-1 space-y-1 list-disc list-inside">
                      {selectedUser.keyCount! > 0 && (
                        <li>{selectedUser.keyCount} SSH key{selectedUser.keyCount! > 1 ? 's' : ''} will be removed</li>
                      )}
                      {selectedUser.authorizationCount! > 0 && (
                        <li>Access to {selectedUser.authorizationCount} host{selectedUser.authorizationCount! > 1 ? 's' : ''} will be revoked</li>
                      )}
                    </ul>
                  </div>
                </div>
              </div>
            )}

            <div className="flex items-center justify-end space-x-3">
              <Button
                variant="secondary"
                onClick={() => {
                  setShowDeleteModal(false);
                  setSelectedUser(null);
                }}
                disabled={submitting}
              >
                Cancel
              </Button>
              <Button
                variant="danger"
                onClick={handleDeleteUser}
                loading={submitting}
              >
                Delete User
              </Button>
            </div>
          </div>
        )}
      </Modal>

      {/* View SSH Keys Modal */}
      <Modal
        isOpen={showKeysModal}
        onClose={() => {
          setShowKeysModal(false);
          setSelectedUser(null);
          setUserDetails(null);
        }}
        title={`SSH Keys - ${selectedUser?.username}`}
        size="lg"
      >
        {selectedUser && (
          <div className="space-y-4">
            {loadingDetails ? (
              <div className="text-center py-8">
                <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600 mx-auto"></div>
                <p className="text-gray-600 dark:text-gray-400 mt-2">Loading SSH keys...</p>
              </div>
            ) : userDetails?.keys.length === 0 ? (
              <div className="text-center py-8">
                <Key size={48} className="mx-auto text-gray-400 dark:text-gray-600" />
                <h3 className="mt-4 text-lg font-medium text-gray-900 dark:text-white">
                  No SSH Keys
                </h3>
                <p className="mt-2 text-gray-500 dark:text-gray-400">
                  This user doesn't have any SSH keys configured.
                </p>
              </div>
            ) : (
              <div className="space-y-3">
                {userDetails?.keys.map((key) => (
                  <div key={key.id} className="border border-gray-200 dark:border-gray-700 rounded-lg p-4">
                    <div className="flex items-start justify-between">
                      <div className="flex-1">
                        <div className="flex items-center space-x-2 mb-2">
                          <span className="bg-blue-100 dark:bg-blue-900/30 text-blue-800 dark:text-blue-300 text-xs font-medium px-2 py-1 rounded">
                            {key.key_type}
                          </span>
                          {key.key_name && (
                            <span className="text-sm text-gray-600 dark:text-gray-400">
                              Name: {key.key_name}
                            </span>
                          )}
                          {key.extra_comment && (
                            <span className="text-sm text-gray-600 dark:text-gray-400 ml-2">
                              Comment: {key.extra_comment}
                            </span>
                          )}
                        </div>
                        <code className="text-xs bg-gray-100 dark:bg-gray-800 text-gray-900 dark:text-gray-100 p-2 rounded block overflow-x-auto">
                          {key.key_type} {key.key_base64.substring(0, 60)}...{key.key_name ? ` ${key.key_name}` : ''}
                        </code>
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            )}
            
            <div className="flex items-center justify-end space-x-3 pt-4 border-t border-gray-200 dark:border-gray-700">
              <Button
                variant="secondary"
                onClick={() => {
                  setShowKeysModal(false);
                  setSelectedUser(null);
                  setUserDetails(null);
                }}
              >
                Close
              </Button>
            </div>
          </div>
        )}
      </Modal>

      {/* View Authorizations Modal */}
      <Modal
        isOpen={showAuthorizationsModal}
        onClose={() => {
          setShowAuthorizationsModal(false);
          setSelectedUser(null);
          setUserDetails(null);
        }}
        title={`Host Access - ${selectedUser?.username}`}
        size="xl"
      >
        {selectedUser && (
          <div className="space-y-4">
            {loadingDetails ? (
              <div className="text-center py-8">
                <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600 mx-auto"></div>
                <p className="text-gray-600 dark:text-gray-400 mt-2">Loading authorizations...</p>
              </div>
            ) : userDetails?.authorizations.length === 0 ? (
              <div className="text-center py-8">
                <Shield size={48} className="mx-auto text-gray-400 dark:text-gray-600" />
                <h3 className="mt-4 text-lg font-medium text-gray-900 dark:text-white">
                  No Host Access
                </h3>
                <p className="mt-2 text-gray-500 dark:text-gray-400">
                  This user doesn't have access to any hosts.
                </p>
              </div>
            ) : (
              <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                {userDetails?.authorizations.map((auth) => {
                  const host = userDetails?.hosts.find(h => h.id === auth.host_id);
                  return (
                    <div key={auth.id} className="border border-gray-200 dark:border-gray-700 rounded-lg p-3">
                      <div className="flex items-center space-x-2 mb-2">
                        <Shield size={14} className="text-green-500" />
                        <div className="flex-1 min-w-0">
                          <div className="font-medium text-gray-900 dark:text-gray-100 text-sm truncate">
                            {host?.name || 'Unknown Host'}
                          </div>
                          {host && (
                            <div className="text-xs text-gray-500 dark:text-gray-400 truncate">
                              {host.address}:{host.port}
                            </div>
                          )}
                        </div>
                      </div>
                      <div className="text-xs space-y-1">
                        <div className="flex items-center space-x-1">
                          <span className="font-medium text-gray-600 dark:text-gray-400">Login as:</span> 
                          <code className="bg-blue-100 dark:bg-blue-900/30 text-blue-800 dark:text-blue-300 px-2 py-1 rounded font-medium">{auth.login}</code>
                        </div>
                        {auth.options && (
                          <div className="flex items-start space-x-1">
                            <span className="font-medium text-gray-600 dark:text-gray-400 mt-0.5">Options:</span> 
                            <code className="bg-gray-100 dark:bg-gray-800 text-gray-900 dark:text-gray-100 px-1 py-0.5 rounded text-xs break-all flex-1">{auth.options}</code>
                          </div>
                        )}
                      </div>
                    </div>
                  );
                })}
              </div>
            )}
            
            <div className="flex items-center justify-end space-x-3 pt-4 border-t border-gray-200 dark:border-gray-700">
              <Button
                variant="secondary"
                onClick={() => {
                  setShowAuthorizationsModal(false);
                  setSelectedUser(null);
                  setUserDetails(null);
                }}
              >
                Close
              </Button>
            </div>
          </div>
        )}
      </Modal>

      {/* Split Keys Modal */}
      <SplitKeysModal
        isOpen={showSplitKeysModal}
        onClose={() => {
          setShowSplitKeysModal(false);
          setSelectedUser(null);
          setUserDetails(null);
        }}
        user={selectedUser}
        userKeys={userDetails?.keys || []}
        userAuthorizations={userDetails?.authorizations || []}
        allHosts={userDetails?.hosts || []}
        onUserUpdated={handleUserUpdated}
      />
    </div>
  );
};

export default UsersPage;