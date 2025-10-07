import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  Users,
  Key,
  Shield,
  AlertTriangle,
  ArrowRight,
  UserPlus,
  Loader2
} from 'lucide-react';
import {
  Modal,
  Button,
  Input,
  Card,
  CardHeader,
  CardTitle,
  CardContent
} from './ui';
import { useNotifications } from '../contexts/NotificationContext';
import { usersService } from '../services/api/users';
import { keysService } from '../services/api/keys';
import { authorizationsService } from '../services/api/authorizations';
import { hostsService } from '../services/api/hosts';
import type {
  User,
  PublicUserKey,
  Host,
  RawAuthorizationResponse
} from '../types';

interface MergeUsersModalProps {
  isOpen: boolean;
  onClose: () => void;
  selectedUsers: MergeableUser[];
  allUsers: MergeableUser[];
  onMergeComplete: () => void;
}

interface MergeableUser extends User {
  keyCount?: number;
  authorizationCount?: number;
}

interface AuthorizationWithHost {
  id: number;
  host_id: number | null;
  host_name: string;
  login: string;
  options?: string;
  comment?: string;
}

interface UserMergeDetails {
  keys: PublicUserKey[];
  authorizations: AuthorizationWithHost[];
}

const MergeUsersModal: React.FC<MergeUsersModalProps> = ({
  isOpen,
  onClose,
  selectedUsers,
  allUsers,
  onMergeComplete
}) => {
  const { showError, showSuccess } = useNotifications();
  const [loadingDetails, setLoadingDetails] = useState(false);
  const [processing, setProcessing] = useState(false);
  const [detailsMap, setDetailsMap] = useState<Record<number, UserMergeDetails>>({});
  const [hosts, setHosts] = useState<Host[]>([]);
  const [hostLookup, setHostLookup] = useState<Record<string, number>>({});
  const [mergeMode, setMergeMode] = useState<'existing' | 'new'>('existing');
  const [targetUserId, setTargetUserId] = useState<number | null>(null);
  const [newUsername, setNewUsername] = useState('');
  const [newUserEnabled, setNewUserEnabled] = useState(true);
  const [newUserComment, setNewUserComment] = useState('');

  const selectedUserIds = useMemo(() => new Set(selectedUsers.map(user => user.id)), [selectedUsers]);

  const existingUsernames = useMemo(() => new Set(allUsers.map(user => user.username.toLowerCase())), [allUsers]);

  const generateSuggestedUsername = useCallback(() => {
    if (selectedUsers.length === 0) {
      return '';
    }

    const baseRaw = selectedUsers[0].username.trim();
    const base = baseRaw.replace(/\s+(copy\d*)$/i, '') || `${baseRaw}-merged`;
    let candidate = base;
    let counter = 1;

    while (existingUsernames.has(candidate.toLowerCase())) {
      counter += 1;
      candidate = `${base}-${counter}`;
    }

    return candidate;
  }, [existingUsernames, selectedUsers]);

  const resetState = useCallback(() => {
    setDetailsMap({});
    setHosts([]);
    setHostLookup({});
    setProcessing(false);
    setMergeMode('existing');
    setTargetUserId(selectedUsers[0]?.id ?? null);
    setNewUsername(generateSuggestedUsername());
    setNewUserEnabled(selectedUsers[0]?.enabled ?? true);
    setNewUserComment(selectedUsers[0]?.comment ?? '');
  }, [generateSuggestedUsername, selectedUsers]);

  const buildHostLookup = (hostList: Host[]): Record<string, number> => {
    const lookup: Record<string, number> = {};
    hostList.forEach(host => {
      lookup[host.name] = host.id;
    });
    return lookup;
  };

  const fetchUserDetails = useCallback(async (user: MergeableUser, lookup: Record<string, number>): Promise<UserMergeDetails> => {
    const [keysResponse, authResponse] = await Promise.all([
      keysService.getKeysForUser(user.username),
      authorizationsService.getUserAuthorizations(user.username)
    ]);

    const keys = (keysResponse.success && keysResponse.data) ? keysResponse.data : [];
    const rawAuths = (authResponse.success ? authResponse.data || [] : []) as unknown as RawAuthorizationResponse[];
    const authorizations: AuthorizationWithHost[] = rawAuths.map(auth => ({
      id: auth.id,
      host_id: lookup[auth.username] ?? null,
      host_name: auth.username,
      login: auth.login,
      options: auth.options,
      comment: auth.comment
    }));

    return { keys, authorizations };
  }, []);

  const ensureUserDetails = useCallback(async (user: MergeableUser): Promise<UserMergeDetails> => {
    if (detailsMap[user.id]) {
      return detailsMap[user.id];
    }

    const lookup = Object.keys(hostLookup).length > 0 ? hostLookup : buildHostLookup(hosts);
    if (Object.keys(lookup).length === 0) {
      throw new Error('Hosts must be loaded before merging users');
    }

    const details = await fetchUserDetails(user, lookup);
    setDetailsMap(prev => ({ ...prev, [user.id]: details }));
    return details;
  }, [detailsMap, fetchUserDetails, hostLookup, hosts]);

  useEffect(() => {
    if (!isOpen) {
      return;
    }

    let cancelled = false;

    const loadData = async () => {
      resetState();

      if (selectedUsers.length < 2) {
        return;
      }

      setLoadingDetails(true);

      try {
        const hostsResponse = await hostsService.getAllHosts();
        if (!hostsResponse.success || !hostsResponse.data) {
          throw new Error(hostsResponse.message || 'Failed to load hosts');
        }

        if (cancelled) {
          return;
        }

        const hostList = hostsResponse.data;
        const lookup = buildHostLookup(hostList);
        setHosts(hostList);
        setHostLookup(lookup);

        const detailEntries = await Promise.all(
          selectedUsers.map(async (user) => {
            const details = await fetchUserDetails(user, lookup);
            return [user.id, details] as const;
          })
        );

        if (cancelled) {
          return;
        }

        setDetailsMap(Object.fromEntries(detailEntries));
      } catch (error) {
        console.error('Failed to load merge data:', error);
        if (!cancelled) {
          showError('Failed to load user data', error instanceof Error ? error.message : 'Please try again later');
          onClose();
        }
      } finally {
        if (!cancelled) {
          setLoadingDetails(false);
        }
      }
    };

    loadData();

    return () => {
      cancelled = true;
    };
  }, [fetchUserDetails, isOpen, onClose, resetState, selectedUsers, showError]);

  const sourceUsersLabel = useMemo(() => {
    return selectedUsers.map(user => user.username).join(', ');
  }, [selectedUsers]);

  const renderSelectedUsersSummary = () => (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center space-x-2">
          <Users size={18} />
          <span>Selected Users</span>
        </CardTitle>
      </CardHeader>
      <CardContent>
        <div className="space-y-3 text-sm text-gray-700 dark:text-gray-300">
          {selectedUsers.map(user => {
            const details = detailsMap[user.id];
            const keyCount = details?.keys.length ?? user.keyCount ?? 0;
            const authCount = details?.authorizations.length ?? user.authorizationCount ?? 0;
            return (
              <div
                key={user.id}
                className="flex items-center justify-between border border-gray-200 dark:border-gray-700 rounded-md px-3 py-2"
              >
                <div className="flex-1 min-w-0">
                  <p className="font-medium text-gray-900 dark:text-gray-100 truncate">{user.username}</p>
                  <p className="text-xs text-gray-500 dark:text-gray-400 truncate">
                    ID #{user.id} • {user.enabled ? 'Enabled' : 'Disabled'}
                  </p>
                </div>
                <div className="flex items-center space-x-3 text-xs">
                  <span className="flex items-center space-x-1">
                    <Key size={14} className="text-blue-500" />
                    <span>{keyCount} key{keyCount === 1 ? '' : 's'}</span>
                  </span>
                  <span className="flex items-center space-x-1">
                    <Shield size={14} className="text-green-500" />
                    <span>{authCount} authorization{authCount === 1 ? '' : 's'}</span>
                  </span>
                </div>
              </div>
            );
          })}
        </div>
      </CardContent>
    </Card>
  );

  const renderMergeOptions = () => (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center space-x-2">
          <ArrowRight size={18} />
          <span>Merged User Destination</span>
        </CardTitle>
      </CardHeader>
      <CardContent>
        <div className="space-y-4">
          <div className="space-y-2">
            <label className="flex items-center space-x-2">
              <input
                type="radio"
                name="merge-mode"
                value="existing"
                checked={mergeMode === 'existing'}
                onChange={() => setMergeMode('existing')}
                className="h-4 w-4 text-blue-600 focus:ring-blue-500 border-gray-300"
              />
              <span className="text-sm text-gray-700 dark:text-gray-300">Merge into an existing user</span>
            </label>
            {mergeMode === 'existing' && (
              <div className="ml-6 space-y-2">
                <label className="block text-xs font-medium text-gray-500 dark:text-gray-400">Destination User</label>
                <select
                  value={targetUserId ?? ''}
                  onChange={(event) => setTargetUserId(Number(event.target.value) || null)}
                  className="w-full rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm px-3 py-2 focus:outline-none focus:ring-2 focus:ring-blue-500"
                >
                  <option value="" disabled>Select user…</option>
                  {allUsers.map(user => (
                    <option key={user.id} value={user.id}>
                      {user.username} {selectedUserIds.has(user.id) ? '• (selected)' : ''}
                    </option>
                  ))}
                </select>
                <p className="text-xs text-gray-500 dark:text-gray-400">
                  Keys and authorizations from the selected users will be moved to this user. The source users will then be deleted.
                </p>
              </div>
            )}
          </div>

          <div className="border-t border-gray-200 dark:border-gray-700 pt-4">
            <label className="flex items-center space-x-2">
              <input
                type="radio"
                name="merge-mode"
                value="new"
                checked={mergeMode === 'new'}
                onChange={() => setMergeMode('new')}
                className="h-4 w-4 text-blue-600 focus:ring-blue-500 border-gray-300"
              />
              <span className="text-sm text-gray-700 dark:text-gray-300">Merge into a new user</span>
            </label>
            {mergeMode === 'new' && (
              <div className="ml-6 space-y-3">
                <div>
                  <label htmlFor="merge-new-username" className="block text-xs font-medium text-gray-500 dark:text-gray-400">New Username</label>
                  <Input
                    id="merge-new-username"
                    value={newUsername}
                    onChange={(event) => setNewUsername(event.target.value)}
                    placeholder="Enter username for merged user"
                    className="w-full"
                  />
                </div>
                <div>
                  <label className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Account Status</label>
                  <select
                    value={newUserEnabled ? 'true' : 'false'}
                    onChange={(event) => setNewUserEnabled(event.target.value === 'true')}
                    className="w-full rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm px-3 py-2 focus:outline-none focus:ring-2 focus:ring-blue-500"
                  >
                    <option value="true">Enabled (Active)</option>
                    <option value="false">Disabled (Inactive)</option>
                  </select>
                </div>
                <div>
                  <label htmlFor="merge-new-comment" className="block text-xs font-medium text-gray-500 dark:text-gray-400">Comment</label>
                  <textarea
                    id="merge-new-comment"
                    value={newUserComment}
                    onChange={(event) => setNewUserComment(event.target.value)}
                    className="w-full rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 text-sm px-3 py-2 focus:outline-none focus:ring-2 focus:ring-blue-500"
                    rows={2}
                    placeholder="Optional comment for merged user"
                  />
                  <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                    The new user will receive all keys and authorizations from the selected users. The original users will be deleted.
                  </p>
                </div>
              </div>
            )}
          </div>
        </div>
      </CardContent>
    </Card>
  );

  const validateMergeInputs = () => {
    if (mergeMode === 'existing') {
      if (!targetUserId) {
        showError('Validation Error', 'Select a user to merge into');
        return false;
      }
      if (selectedUsers.every(user => user.id === targetUserId)) {
        showError('Validation Error', 'Select at least one different user to merge');
        return false;
      }
    } else {
      if (!newUsername.trim()) {
        showError('Validation Error', 'Enter a username for the merged user');
        return false;
      }
      const usernameExists = existingUsernames.has(newUsername.trim().toLowerCase());
      if (usernameExists) {
        showError('Validation Error', 'Username already exists. Choose a different username.');
        return false;
      }
    }

    return true;
  };

  const handleMerge = async () => {
    if (processing || loadingDetails) {
      return;
    }

    if (!validateMergeInputs()) {
      return;
    }

    try {
      setProcessing(true);

      let targetUser: MergeableUser | null = null;

      if (mergeMode === 'existing') {
        targetUser = allUsers.find(user => user.id === targetUserId) ?? null;
        if (!targetUser) {
          throw new Error('Target user could not be found');
        }
      } else {
        const createResponse = await usersService.createUser({
          username: newUsername.trim(),
          enabled: newUserEnabled,
          comment: newUserComment.trim() !== '' ? newUserComment.trim() : undefined
        });

        if (!createResponse.success) {
          throw new Error(createResponse.message || 'Failed to create destination user');
        }

        const refreshedUsers = await usersService.getAllUsers();
        if (!refreshedUsers.success || !refreshedUsers.data) {
          throw new Error('Failed to refresh users after creation');
        }

        const created = refreshedUsers.data.find(user => user.username === newUsername.trim());
        if (!created) {
          throw new Error('Created user not found after creation');
        }

        targetUser = { ...created, keyCount: 0, authorizationCount: 0 };
      }

      if (!targetUser) {
        throw new Error('Destination user is required');
      }

      const targetDetails = await ensureUserDetails(targetUser);
      const authorizationFingerprints = new Set(
        targetDetails.authorizations.map(auth => `${auth.host_id ?? 'missing'}|${auth.login}|${auth.options ?? ''}`)
      );

      const usersToMerge = mergeMode === 'existing'
        ? selectedUsers.filter(user => user.id !== targetUser!.id)
        : selectedUsers;

      let movedKeys = 0;
      let copiedAuthorizations = 0;
      const skippedAuthorizations: string[] = [];

      for (const user of usersToMerge) {
        const details = await ensureUserDetails(user);

        for (const key of details.keys) {
          const assignResponse = await usersService.assignKeyToUser({
            user_id: targetUser.id,
            key_type: key.key_type,
            key_base64: key.key_base64,
            key_name: key.key_name || null,
            extra_comment: key.extra_comment || null
          });

          if (!assignResponse.success) {
            throw new Error(assignResponse.message || `Failed to assign key ${key.id} to ${targetUser.username}`);
          }

          const deleteResponse = await keysService.deleteKey(key.id);
          if (!deleteResponse.success) {
            throw new Error(deleteResponse.message || `Failed to remove key ${key.id} from ${user.username}`);
          }

          movedKeys += 1;
        }

        for (const auth of details.authorizations) {
          if (!auth.host_id) {
            skippedAuthorizations.push(`${auth.host_name} (${auth.login})`);
            continue;
          }

          const fingerprint = `${auth.host_id}|${auth.login}|${auth.options ?? ''}`;
          if (authorizationFingerprints.has(fingerprint)) {
            continue;
          }

          const createAuthResponse = await authorizationsService.createAuthorization({
            host_id: auth.host_id,
            user_id: targetUser.id,
            login: auth.login,
            options: auth.options
          });

          if (!createAuthResponse.success) {
            throw new Error(createAuthResponse.message || `Failed to copy authorization ${auth.id}`);
          }

          authorizationFingerprints.add(fingerprint);
          copiedAuthorizations += 1;
        }

        const deleteUserResponse = await usersService.deleteUser(user.username);
        if (!deleteUserResponse.success) {
          throw new Error(deleteUserResponse.message || `Failed to delete user ${user.username}`);
        }
      }

      const messages: string[] = [];
      messages.push(`Moved ${movedKeys} key${movedKeys === 1 ? '' : 's'}`);
      messages.push(`Copied ${copiedAuthorizations} authorization${copiedAuthorizations === 1 ? '' : 's'}`);
      if (skippedAuthorizations.length > 0) {
        messages.push(`Skipped ${skippedAuthorizations.length} authorization${skippedAuthorizations.length === 1 ? '' : 's'} without matching hosts`);
      }

      showSuccess('Users merged successfully', messages.join(' • '));
      onMergeComplete();
    } catch (error) {
      console.error('Merge users failed:', error);
      showError('Merge failed', error instanceof Error ? error.message : 'An unexpected error occurred while merging users');
    } finally {
      setProcessing(false);
    }
  };

  if (!isOpen) {
    return null;
  }

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Merge Users"
      size="xl"
    >
      {selectedUsers.length < 2 ? (
        <div className="text-center py-8">
          <AlertTriangle size={40} className="mx-auto text-yellow-500" />
          <p className="mt-4 text-sm text-gray-600 dark:text-gray-300">
            Select at least two users to merge them into a single account.
          </p>
        </div>
      ) : (
        <div className="space-y-5">
          <div className="bg-blue-50 dark:bg-blue-900/20 p-4 rounded-lg">
            <div className="flex items-start space-x-3">
              <UserPlus className="text-blue-600 dark:text-blue-400 mt-1" size={20} />
              <div className="text-sm text-blue-900 dark:text-blue-100">
                <p className="font-medium">Merge Users</p>
                <p>
                  Combine users <strong>{sourceUsersLabel}</strong> into a single account. All SSH keys and host authorizations will be moved to the destination user.
                </p>
              </div>
            </div>
          </div>

          {loadingDetails ? (
            <div className="flex items-center justify-center py-16">
              <Loader2 className="animate-spin text-blue-600" size={32} />
            </div>
          ) : (
            <>
              {renderSelectedUsersSummary()}
              {renderMergeOptions()}
            </>
          )}

          <div className="border-t border-gray-200 dark:border-gray-700 pt-4 flex items-center justify-end space-x-3">
            <Button
              variant="secondary"
              onClick={onClose}
              disabled={processing}
            >
              Cancel
            </Button>
            <Button
              onClick={handleMerge}
              loading={processing}
              disabled={loadingDetails || processing}
            >
              Merge Users
            </Button>
          </div>
        </div>
      )}
    </Modal>
  );
};

export default MergeUsersModal;
