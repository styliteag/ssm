import React, { useState } from 'react';
import { AlertTriangle, Trash2, Users, Key, Shield } from 'lucide-react';
import {
  Modal,
  Button,
  Card,
  CardHeader,
  CardTitle,
  CardContent
} from './ui';
import { useNotifications } from '../contexts/NotificationContext';
import { usersService } from '../services/api/users';
import type { User } from '../types';

interface BulkDeleteUsersModalProps {
  isOpen: boolean;
  onClose: () => void;
  usersToDelete: Array<User & { keyCount?: number; authorizationCount?: number }>;
  onDeleteComplete: () => void;
}

const BulkDeleteUsersModal: React.FC<BulkDeleteUsersModalProps> = ({
  isOpen,
  onClose,
  usersToDelete,
  onDeleteComplete
}) => {
  const { showError, showSuccess } = useNotifications();
  const [deleting, setDeleting] = useState(false);

  if (!isOpen) {
    return null;
  }

  const handleDelete = async () => {
    if (usersToDelete.length === 0) {
      onClose();
      return;
    }

    try {
      setDeleting(true);
      const failures: string[] = [];
      let deletedCount = 0;

      for (const user of usersToDelete) {
        const response = await usersService.deleteUser(user.username);
        if (!response.success) {
          failures.push(user.username);
        } else {
          deletedCount += 1;
        }
      }

      if (deletedCount > 0) {
        showSuccess(
          'Users deleted',
          `Deleted ${deletedCount} user${deletedCount === 1 ? '' : 's'}`
        );
      }

      if (failures.length > 0) {
        showError(
          'Delete users failed',
          `Could not delete: ${failures.join(', ')}`
        );
      }

      setDeleting(false);
      onDeleteComplete();
    } catch (error) {
      console.error('Bulk delete users failed:', error);
      showError('Delete users failed', error instanceof Error ? error.message : 'An unexpected error occurred');
      setDeleting(false);
    }
  };

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Delete Selected Users"
      size="lg"
    >
      <div className="space-y-5">
        <div className="bg-red-50 dark:bg-red-900/20 p-4 rounded-lg">
          <div className="flex items-start space-x-3">
            <AlertTriangle className="text-red-600 dark:text-red-400 mt-1" size={20} />
            <div className="text-sm text-red-800 dark:text-red-200">
              <p className="font-medium">This action cannot be undone.</p>
              <p>
                All SSH keys and host authorizations associated with the selected users will be permanently removed.
              </p>
            </div>
          </div>
        </div>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center space-x-2">
              <Users size={18} />
              <span>Users to delete ({usersToDelete.length})</span>
            </CardTitle>
          </CardHeader>
          <CardContent>
            <div className="space-y-3 max-h-64 overflow-y-auto">
              {usersToDelete.map((user) => (
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
                      <span>{user.keyCount ?? 0} key{(user.keyCount ?? 0) === 1 ? '' : 's'}</span>
                    </span>
                    <span className="flex items-center space-x-1">
                      <Shield size={14} className="text-green-500" />
                      <span>{user.authorizationCount ?? 0} authorization{(user.authorizationCount ?? 0) === 1 ? '' : 's'}</span>
                    </span>
                  </div>
                </div>
              ))}
            </div>
          </CardContent>
        </Card>

        <div className="border-t border-gray-200 dark:border-gray-700 pt-4 flex items-center justify-end space-x-3">
          <Button
            variant="secondary"
            onClick={onClose}
            disabled={deleting}
          >
            Cancel
          </Button>
          <Button
            variant="danger"
            onClick={handleDelete}
            loading={deleting}
          >
            <Trash2 className="mr-2" size={16} />
            Delete Users
          </Button>
        </div>
      </div>
    </Modal>
  );
};

export default BulkDeleteUsersModal;
