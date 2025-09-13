import React, { useState, useEffect, useCallback } from 'react';
import {
  AlertTriangle,
  User,
  Key,
  Shield,
  Copy,
  UserPlus
} from 'lucide-react';
import {
  Modal,
  Button,
  Input,
  Card,
  CardContent,
  CardHeader,
  CardTitle
} from './ui';
import { useNotifications } from '../contexts/NotificationContext';
import { usersService } from '../services/api/users';
import { keysService } from '../services/api/keys';
import { authorizationsService } from '../services/api/authorizations';
import type {
  User as UserType,
  PublicUserKey,
  Authorization,
  Host
} from '../types';

interface SplitKeysModalProps {
  isOpen: boolean;
  onClose: () => void;
  user: UserType | null;
  userKeys: PublicUserKey[];
  userAuthorizations: Authorization[];
  allHosts: Host[];
  onUserUpdated: () => void;
}

interface SplitKeysFormData {
  newUsername: string;
  selectedKeys: number[];
  selectedAuthorizations: number[];
}

const SplitKeysModal: React.FC<SplitKeysModalProps> = ({
  isOpen,
  onClose,
  user,
  userKeys,
  userAuthorizations,
  allHosts,
  onUserUpdated
}) => {
  const { showSuccess, showError } = useNotifications();
  const [loading, setLoading] = useState(false);
  const [formData, setFormData] = useState<SplitKeysFormData>({
    newUsername: '',
    selectedKeys: [],
    selectedAuthorizations: []
  });

  const generateUsernameSuggestion = useCallback(async () => {
    if (!user) return;

    const baseUsername = `${user.username} copy`;
    let suggestedUsername = baseUsername;
    let counter = 2;

    // Check if username exists and increment counter if needed
    const allUsersResponse = await usersService.getAllUsers();
    if (allUsersResponse.success && allUsersResponse.data) {
      const existingUsernames = allUsersResponse.data.map(u => u.username.toLowerCase());

      while (existingUsernames.includes(suggestedUsername.toLowerCase())) {
        suggestedUsername = `${baseUsername}${counter}`;
        counter++;
      }
    }

    setFormData(prev => ({
      ...prev,
      newUsername: suggestedUsername
    }));
  }, [user]);

  // Generate username suggestion and select all authorizations by default when modal opens
  useEffect(() => {
    if (isOpen && user) {
      generateUsernameSuggestion();
      // Select all authorizations by default
      setFormData(prev => ({
        ...prev,
        selectedAuthorizations: userAuthorizations.map(auth => auth.id)
      }));
    }
  }, [isOpen, user, userAuthorizations, generateUsernameSuggestion]);

  const handleKeyToggle = (keyId: number) => {
    setFormData(prev => ({
      ...prev,
      selectedKeys: prev.selectedKeys.includes(keyId)
        ? prev.selectedKeys.filter(id => id !== keyId)
        : [...prev.selectedKeys, keyId]
    }));
  };

  const handleAuthorizationToggle = (authId: number) => {
    setFormData(prev => ({
      ...prev,
      selectedAuthorizations: prev.selectedAuthorizations.includes(authId)
        ? prev.selectedAuthorizations.filter(id => id !== authId)
        : [...prev.selectedAuthorizations, authId]
    }));
  };

  const handleSubmit = async () => {
    if (!user || !formData.newUsername.trim()) {
      showError('Validation Error', 'Please enter a username for the new user');
      return;
    }

    // Check if username already exists
    const allUsersResponse = await usersService.getAllUsers();
    if (allUsersResponse.success && allUsersResponse.data) {
      const exists = allUsersResponse.data.some(u => u.username.toLowerCase() === formData.newUsername.trim().toLowerCase());
      if (exists) {
        showError('Validation Error', 'Username already exists. Please choose a different username.');
        return;
      }
    }

    if (formData.selectedKeys.length === 0) {
      showError('Validation Error', 'Please select at least one key to split');
      return;
    }

    // Ensure at least one key remains with original user
    const remainingKeysCount = userKeys.length - formData.selectedKeys.length;
    if (remainingKeysCount < 1) {
      showError('Validation Error', 'Original user must keep at least one key');
      return;
    }

    setLoading(true);

    try {
      // 1. Create new user
      const newUserResponse = await usersService.createUser({
        username: formData.newUsername.trim(),
        enabled: user.enabled,
        comment: `Split from ${user.username}`
      });

      if (!newUserResponse.success || !newUserResponse.data) {
        throw new Error(newUserResponse.message || 'Failed to create new user');
      }

      // The backend returns username in 'id' field, we need to find the actual numeric ID
      // Fetch the user list again to get the newly created user with proper ID
      const freshUsersResponse = await usersService.getAllUsers();
      if (!freshUsersResponse.success || !freshUsersResponse.data) {
        throw new Error('Could not fetch users to find the newly created user');
      }

      // Find the newly created user to get the proper numeric ID
      const newUser = freshUsersResponse.data.find(u => u.username === formData.newUsername.trim());

      if (!newUser) {
        throw new Error('User was created but could not be found to assign keys');
      }

      // 2. Move selected keys to new user (delete from old, create for new)
      for (const keyId of formData.selectedKeys) {
        const key = userKeys.find(k => k.id === keyId);
        if (!key) continue;

        // Delete key from original user
        await keysService.deleteKey(keyId);

        // Create new key for new user
        await usersService.assignKeyToUser({
          user_id: newUser.id,
          key_type: key.key_type,
          key_base64: key.key_base64,
          key_name: key.key_name || null,
          extra_comment: key.extra_comment || null
        });
      }

      // 3. Copy selected authorizations to new user
      for (const authId of formData.selectedAuthorizations) {
        const auth = userAuthorizations.find(a => a.id === authId);
        if (!auth) continue;

        await authorizationsService.createAuthorization({
          host_id: auth.host_id,
          user_id: newUser.id,
          login: auth.login,
          options: auth.options
        });
      }

      showSuccess('Keys Split Successfully',
        `Created user "${newUser.username}" with ${formData.selectedKeys.length} key(s) and ${formData.selectedAuthorizations.length} authorization(s)`
      );

      onUserUpdated();
      onClose();

    } catch (error) {
      console.error('Split keys error:', error);
      showError('Split Failed', error instanceof Error ? error.message : 'An unexpected error occurred');
    } finally {
      setLoading(false);
    }
  };


  if (!user) return null;

  const remainingKeysCount = userKeys.length - formData.selectedKeys.length;

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={`Split Keys - ${user.username}`}
      size="xl"
    >
      <div className="space-y-6">
        {/* Header Info */}
        <div className="bg-blue-50 dark:bg-blue-900/20 p-4 rounded-lg">
          <div className="flex items-start space-x-3">
            <UserPlus className="text-blue-600 dark:text-blue-400 mt-1" size={20} />
            <div>
              <h3 className="text-lg font-medium text-blue-900 dark:text-blue-100">
                Split User Keys
              </h3>
              <p className="text-sm text-blue-700 dark:text-blue-300 mt-1">
                Create a new user with selected keys and authorizations from <strong>{user.username}</strong>.
                The original user will keep the unselected keys.
              </p>
            </div>
          </div>
        </div>

        {/* New User Details */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center space-x-2">
              <User size={18} />
              <span>New User Details</span>
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="space-y-4">
              <div>
                <label htmlFor="newUsername" className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                  New Username
                </label>
                <Input
                  id="newUsername"
                  type="text"
                  value={formData.newUsername}
                  onChange={(e) => setFormData(prev => ({ ...prev, newUsername: e.target.value }))}
                  placeholder="Enter username for new user"
                  className="w-full"
                  helperText="Username for the user that will receive the split keys"
                />
              </div>
            </div>
          </CardContent>
        </Card>

        {/* Key Selection */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center justify-between">
              <div className="flex items-center space-x-2">
                <Key size={18} />
                <span>Select Keys to Split ({formData.selectedKeys.length} selected)</span>
              </div>
              <div className="text-sm text-gray-600 dark:text-gray-400">
                {remainingKeysCount} key{remainingKeysCount !== 1 ? 's' : ''} will remain with original user
              </div>
            </CardTitle>
          </CardHeader>
          <CardContent>
            {remainingKeysCount < 1 && (
              <div className="bg-red-50 dark:bg-red-900/20 p-3 rounded-md mb-4">
                <div className="flex items-start space-x-2">
                  <AlertTriangle className="text-red-600 dark:text-red-400 mt-1" size={16} />
                  <div className="text-sm text-red-800 dark:text-red-200">
                    <p className="font-medium">Validation Error</p>
                    <p>The original user must keep at least one key. Please deselect some keys.</p>
                  </div>
                </div>
              </div>
            )}

            <div className="space-y-3">
              {userKeys.map((key) => (
                <div key={key.id} className="flex items-start space-x-3 p-3 border border-gray-200 dark:border-gray-700 rounded-lg">
                  <input
                    type="checkbox"
                    id={`key-${key.id}`}
                    checked={formData.selectedKeys.includes(key.id)}
                    onChange={() => handleKeyToggle(key.id)}
                    className="mt-1 h-4 w-4 text-blue-600 focus:ring-blue-500 border-gray-300 rounded"
                  />
                  <label htmlFor={`key-${key.id}`} className="flex-1 cursor-pointer">
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
                      {key.key_type} {key.key_base64.substring(0, 60)}...
                    </code>
                  </label>
                </div>
              ))}
            </div>
          </CardContent>
        </Card>

        {/* Authorization Selection */}
        <Card>
          <CardHeader>
            <CardTitle className="flex items-center space-x-2">
              <Shield size={18} />
              <span>Copy Authorizations ({formData.selectedAuthorizations.length} selected)</span>
            </CardTitle>
            {userAuthorizations.length > 0 && (
              <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                All authorizations are selected by default. Uncheck any you don't want to copy.
              </p>
            )}
          </CardHeader>
          <CardContent>
            {userAuthorizations.length === 0 ? (
              <div className="text-center py-8">
                <Shield size={48} className="mx-auto text-gray-400 dark:text-gray-600" />
                <h3 className="mt-4 text-lg font-medium text-gray-900 dark:text-white">
                  No Authorizations
                </h3>
                <p className="mt-2 text-gray-500 dark:text-gray-400">
                  This user has no host authorizations to copy.
                </p>
              </div>
            ) : (
              <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                {userAuthorizations.map((auth) => {
                  const host = allHosts.find(h => h.id === auth.host_id);
                  return (
                    <div key={auth.id} className="flex items-start space-x-3 p-3 border border-gray-200 dark:border-gray-700 rounded-lg">
                      <input
                        type="checkbox"
                        id={`auth-${auth.id}`}
                        checked={formData.selectedAuthorizations.includes(auth.id)}
                        onChange={() => handleAuthorizationToggle(auth.id)}
                        className="mt-1 h-4 w-4 text-blue-600 focus:ring-blue-500 border-gray-300 rounded"
                      />
                      <label htmlFor={`auth-${auth.id}`} className="flex-1 cursor-pointer">
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
                            <code className="bg-blue-100 dark:bg-blue-900/30 text-blue-800 dark:text-blue-300 px-2 py-1 rounded font-medium">
                              {auth.login}
                            </code>
                          </div>
                          {auth.options && (
                            <div className="flex items-start space-x-1">
                              <span className="font-medium text-gray-600 dark:text-gray-400 mt-0.5">Options:</span>
                              <code className="bg-gray-100 dark:bg-gray-800 text-gray-900 dark:text-gray-100 px-1 py-0.5 rounded text-xs break-all flex-1">
                                {auth.options}
                              </code>
                            </div>
                          )}
                        </div>
                      </label>
                    </div>
                  );
                })}
              </div>
            )}
          </CardContent>
        </Card>

        {/* Actions */}
        <div className="flex items-center justify-end space-x-3 pt-4 border-t border-gray-200 dark:border-gray-700">
          <Button
            variant="secondary"
            onClick={onClose}
            disabled={loading}
          >
            Cancel
          </Button>
          <Button
            onClick={handleSubmit}
            loading={loading}
            disabled={formData.selectedKeys.length === 0 || remainingKeysCount < 1}
          >
            <Copy className="mr-2" size={16} />
            Split Keys
          </Button>
        </div>
      </div>
    </Modal>
  );
};

export default SplitKeysModal;
