import React, { useState } from 'react';
import { Modal, Form, type FormField } from './ui';
import { hostsService } from '../services/api/hosts';
import { useNotifications } from '../contexts/NotificationContext';
import type { Host, HostFormData } from '../types';

interface HostEditModalProps {
  isOpen: boolean;
  onClose: () => void;
  host: Host | null;
  onHostUpdated?: (updatedHost: Host) => void;
  jumpHosts?: Host[];
}

export const HostEditModal: React.FC<HostEditModalProps> = ({
  isOpen,
  onClose,
  host,
  onHostUpdated,
  jumpHosts = []
}) => {
  const { showSuccess, showError } = useNotifications();
  const [submitting, setSubmitting] = useState(false);

  // Form field definitions for host editing
  const getFormFields = (): FormField[] => [
    {
      name: 'name',
      label: 'Host Name',
      type: 'text',
      required: true,
      placeholder: 'Enter a unique name for this host',
      helperText: 'A friendly name to identify this host',
      validation: {
        minLength: 2,
        maxLength: 50,
        pattern: /^[a-zA-Z0-9\-_.]+$/
      }
    },
    {
      name: 'address',
      label: 'Hostname/IP Address',
      type: 'text',
      required: true,
      placeholder: 'example.com or 192.168.1.100',
      helperText: 'The hostname or IP address of the SSH server'
    },
    {
      name: 'port',
      label: 'SSH Port',
      type: 'number',
      required: true,
      placeholder: '22',
      helperText: 'SSH port (typically 22)',
      validation: {
        min: 1,
        max: 65535
      }
    },
    {
      name: 'username',
      label: 'SSH Username',
      type: 'text',
      required: true,
      placeholder: 'root or ubuntu',
      helperText: 'Username for SSH authentication'
    },
    {
      name: 'key_fingerprint',
      label: 'SSH Key Fingerprint',
      type: 'text',
      placeholder: 'SHA256:...',
      helperText: 'Optional: Expected SSH host key fingerprint for verification'
    },
    {
      name: 'jump_via',
      label: 'Jump Host',
      type: 'select',
      placeholder: 'Select a jump host (optional)',
      helperText: 'Optional: Use another host as a jump/bastion host',
      options: [
        { value: '', label: 'None (no jump host)' },
        ...jumpHosts
          .filter(h => h.id !== host?.id)
          .map(h => ({
            value: h.id.toString(),
            label: `${h.name} (${h.address})`
          }))
      ]
    }
  ];

  // Handle edit host
  const handleEditHost = async (values: HostFormData) => {
    if (!host) return;
    
    try {
      setSubmitting(true);
      const hostData = {
        name: values.name,
        address: values.address,
        port: Number(values.port),
        username: values.username,
        jump_via: values.jump_via && String(values.jump_via) !== '' ? String(values.jump_via) : '',
        key_fingerprint: values.key_fingerprint && values.key_fingerprint.trim() !== '' ? values.key_fingerprint.trim() : ''
      };
      
      const response = await hostsService.updateHost(host.name, {
        name: hostData.name,
        address: hostData.address,
        port: hostData.port,
        username: hostData.username,
        key_fingerprint: hostData.key_fingerprint,
        jump_via: hostData.jump_via ? Number(hostData.jump_via) : undefined
      });
      
      if (response.success) {
        onClose();
        showSuccess('Host updated', `${hostData.name} has been updated successfully`);
        
        // Notify parent component with updated data
        if (onHostUpdated) {
          onHostUpdated({
            ...host,
            name: hostData.name,
            address: hostData.address,
            port: hostData.port,
            username: hostData.username,
            key_fingerprint: hostData.key_fingerprint || undefined,
            jump_via: hostData.jump_via ? Number(hostData.jump_via) : undefined
          });
        }
      } else {
        showError('Failed to update host', response.message || 'Please check your input and try again');
      }
    } catch (error) {
      console.error('Host update error:', error);
      showError('Failed to update host', 'Please check your input and try again');
    } finally {
      setSubmitting(false);
    }
  };

  if (!host) return null;

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title="Edit Host"
      size="lg"
    >
      <Form
        fields={getFormFields()}
        onSubmit={(values) => handleEditHost(values as unknown as HostFormData)}
        submitText="Save Changes"
        cancelText="Cancel"
        onCancel={onClose}
        loading={submitting}
        layout="grid"
        gridCols={2}
        initialValues={{
          name: host.name,
          address: host.address,
          port: host.port,
          username: host.username,
          key_fingerprint: host.key_fingerprint || '',
          jump_via: host.jump_via?.toString() || ''
        }}
      />
    </Modal>
  );
};

export default HostEditModal;