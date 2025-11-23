import React, { useState } from 'react';
import { Users, Settings } from 'lucide-react';
import { Modal, Form, type FormField } from './ui';
import type { Host } from '../types';

interface BulkEditModalProps {
  isOpen: boolean;
  onClose: () => void;
  selectedHosts: Host[];
  jumpHosts: Host[];
  onBulkUpdate: (updateData: BulkUpdateData) => Promise<void>;
}

export interface BulkUpdateData {
  jump_via?: number | null;
  disabled?: boolean;
}

const BulkEditModal: React.FC<BulkEditModalProps> = ({
  isOpen,
  onClose,
  selectedHosts,
  jumpHosts,
  onBulkUpdate
}) => {
  const [loading, setLoading] = useState(false);

  const handleSubmit = async (values: Record<string, unknown>) => {
    try {
      setLoading(true);
      
      const updateData: BulkUpdateData = {};
      
      // Only include fields that have been changed from default
      if (values.jump_via !== undefined && values.jump_via !== '') {
        if (values.jump_via === 'null') {
          // Explicitly set to null to remove jump host
          updateData.jump_via = null;
        } else {
          // Convert to number for specific jump host ID
          updateData.jump_via = Number(values.jump_via);
        }
      }
      
      if (values.disabled !== undefined && values.disabled !== '') {
        updateData.disabled = values.disabled === 'true';
      }
      
      await onBulkUpdate(updateData);
      onClose();
    } catch (error) {
      console.error('Bulk update failed:', error);
    } finally {
      setLoading(false);
    }
  };

  const getFormFields = (): FormField[] => [
    {
      name: 'jump_via',
      label: 'Jump Host',
      type: 'select',
      placeholder: 'Select jump host (leave unchanged if empty)',
      helperText: 'Set jump host for all selected hosts. Leave empty to keep existing values.',
      options: [
        { value: '', label: '(Keep existing values)' },
        { value: 'null', label: 'None (remove jump host)' },
        ...jumpHosts
          .filter(host => !selectedHosts.some(selected => selected.id === host.id))
          .map(host => ({
            value: String(host.id),
            label: `${host.name} (${host.address})`
          }))
      ]
    },
    {
      name: 'disabled',
      label: 'Status',
      type: 'select',
      placeholder: 'Select status (leave unchanged if empty)',
      helperText: 'Set enabled/disabled status for all selected hosts.',
      options: [
        { value: '', label: '(Keep existing values)' },
        { value: 'false', label: 'Enabled' },
        { value: 'true', label: 'Disabled' }
      ]
    }
  ];

  return (
    <Modal
      isOpen={isOpen}
      onClose={onClose}
      title={
        <div className="flex items-center space-x-2">
          <Settings size={20} />
          <span>Bulk Edit Hosts</span>
        </div>
      }
      size="lg"
    >
      <div className="space-y-4">
        {/* Selected hosts summary */}
        <div className="bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg p-4">
          <div className="flex items-center space-x-2 mb-2">
            <Users size={16} className="text-blue-600 dark:text-blue-400" />
            <span className="font-medium text-blue-900 dark:text-blue-100">
              Editing {selectedHosts.length} host{selectedHosts.length !== 1 ? 's' : ''}
            </span>
          </div>
          <div className="text-sm text-blue-800 dark:text-blue-300">
            <div className="max-h-32 overflow-y-auto space-y-1">
              {selectedHosts.map(host => (
                <div key={host.id} className="flex items-center justify-between">
                  <span className="font-medium">{host.name}</span>
                  <span className="text-xs opacity-75">{host.address}</span>
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Form */}
        <Form
          fields={getFormFields()}
          onSubmit={handleSubmit}
          submitText="Update Hosts"
          cancelText="Cancel"
          onCancel={onClose}
          loading={loading}
          layout="vertical"
          initialValues={{}}
        />
      </div>
    </Modal>
  );
};

export default BulkEditModal;