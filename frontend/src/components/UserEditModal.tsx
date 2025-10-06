import React, { useState } from 'react';
import { Modal, Form, type FormField } from './ui';
import { usersService } from '../services/api/users';
import { useNotifications } from '../contexts/NotificationContext';
import type { User } from '../types';

interface UserEditModalProps {
  isOpen: boolean;
  onClose: () => void;
  user: User | null;
  onUserUpdated?: (updatedUser: User) => void;
  users?: User[];
}

export const UserEditModal: React.FC<UserEditModalProps> = ({
  isOpen,
  onClose,
  user,
  onUserUpdated,
  users = []
}) => {
  const { showSuccess, showError } = useNotifications();
  const [submitting, setSubmitting] = useState(false);

  // Form field definitions for user editing
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
        pattern: /^[a-zA-Z0-9\-_.\s@#]+$/,
        custom: (value: unknown) => {
          // Only check for duplicates if username is being changed
          if (user && (value as string) === user.username) return null;
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

  // Handle edit user
  const handleEditUser = async (values: Record<string, unknown>) => {
    if (!user) return;
    
    try {
      setSubmitting(true);
      const userData = {
        username: values.username as string,
        enabled: values.enabled === 'true',
        comment: values.comment ? (values.comment as string).trim() : ''
      };
      
      const response = await usersService.updateUser(user.username, userData);
      
      if (response.success) {
        onClose();
        showSuccess('User updated', `${userData.username} has been updated successfully`);
        
        // Notify parent component with updated data
        if (onUserUpdated) {
          onUserUpdated({
            ...user,
            username: userData.username,
            enabled: userData.enabled,
            comment: userData.comment
          });
        }
      } else {
        showError('Failed to update user', response.message || 'Please check your input and try again');
      }
    } catch (error) {
      console.error('User update error:', error);
      showError('Failed to update user', 'Please check your input and try again');
    } finally {
      setSubmitting(false);
    }
  };

  if (!user) return null;

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Edit User"
      size="md"
    >
      <Form
        fields={getFormFields()}
        onSubmit={(values) => handleEditUser(values)}
        submitText="Save Changes"
        cancelText="Cancel"
        onCancel={onClose}
        loading={submitting}
        initialValues={{
          username: user.username,
          enabled: user.enabled.toString(),
          comment: user.comment || ''
        }}
      />
    </Modal>
  );
};

export default UserEditModal;