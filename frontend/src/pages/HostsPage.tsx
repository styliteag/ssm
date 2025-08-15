import React, { useState, useEffect, useCallback } from 'react';
import { useLocation } from 'react-router-dom';
import { 
  Server, 
  Plus, 
  Edit2, 
  Trash2, 
  Activity, 
  AlertCircle, 
  CheckCircle, 
  Clock
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
import { hostsService } from '../services/api/hosts';
import type { 
  Host, 
  HostFormData
} from '../types';

interface ExtendedHost extends Host {
  connectionStatus?: 'online' | 'offline' | 'testing' | 'unknown';
  lastTested?: Date;
  [key: string]: unknown;
}

const HostsPage: React.FC = () => {
  const location = useLocation();
  const { showSuccess, showError } = useNotifications();
  
  
  // State management
  const [hosts, setHosts] = useState<ExtendedHost[]>([]);
  const [jumpHosts, setJumpHosts] = useState<Host[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedHost, setSelectedHost] = useState<ExtendedHost | null>(null);
  
  // Modal states
  const [showAddModal, setShowAddModal] = useState(false);
  const [showEditModal, setShowEditModal] = useState(false);
  const [showDeleteModal, setShowDeleteModal] = useState(false);
  
  // Form loading states
  const [submitting, setSubmitting] = useState(false);
  const [testing, setTesting] = useState<Record<number, boolean>>({});

  // Load hosts on component mount
  const loadHosts = useCallback(async () => {
    try {
      setLoading(true);
      const response = await hostsService.getHosts();
      if (response.success && response.data) {
        setHosts(response.data.items.map(host => ({
          ...host,
          connectionStatus: 'unknown' as const
        })));
      }
    } catch {
      showError('Failed to load hosts', 'Please try again later');
    } finally {
      setLoading(false);
    }
  }, [showError]);

  // Load jump hosts for dropdown
  const loadJumpHosts = useCallback(async () => {
    try {
      const response = await hostsService.getAllHosts();
      if (response.success && response.data) {
        setJumpHosts(response.data);
      }
    } catch (error) {
      console.error('Failed to load jump hosts:', error);
    }
  }, []);

  useEffect(() => {
    loadHosts();
    loadJumpHosts();
  }, [loadHosts, loadJumpHosts]);

  // Test SSH connection
  const testConnection = useCallback(async (host: ExtendedHost) => {
    try {
      setTesting(prev => ({ ...prev, [host.id]: true }));
      setHosts(prev => prev.map(h => 
        h.id === host.id 
          ? { ...h, connectionStatus: 'testing' }
          : h
      ));

      const response = await hostsService.testConnection(host.id);
      const status = response.success && response.data?.success ? 'online' : 'offline';
      
      setHosts(prev => prev.map(h => 
        h.id === host.id 
          ? { ...h, connectionStatus: status, lastTested: new Date() }
          : h
      ));

      if (status === 'online') {
        showSuccess('Connection successful', `Successfully connected to ${host.name}`);
      } else {
        showError('Connection failed', response.data?.message || 'Unable to connect to host');
      }
    } catch {
      setHosts(prev => prev.map(h => 
        h.id === host.id 
          ? { ...h, connectionStatus: 'offline', lastTested: new Date() }
          : h
      ));
      showError('Connection test failed', 'Please check your network connection');
    } finally {
      setTesting(prev => ({ ...prev, [host.id]: false }));
    }
  }, [showSuccess, showError]);

  // Form field definitions
  const getFormFields = (isEdit: boolean = false): FormField[] => [
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
        pattern: /^[a-zA-Z0-9\-_.]+$/,
        custom: (value: unknown) => {
          if (isEdit) return null;
          const exists = hosts.some(h => h.name.toLowerCase() === (value as string).toLowerCase());
          return exists ? 'Host name already exists' : null;
        }
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
      options: jumpHosts.map(host => ({
        value: host.id,
        label: `${host.name} (${host.address})`
      }))
    }
  ];

  // Handle form submissions
  const handleAddHost = async (values: HostFormData) => {
    try {
      setSubmitting(true);
      const hostData = {
        ...values,
        port: Number(values.port),
        jump_via: values.jump_via ? Number(values.jump_via) : undefined,
        key_fingerprint: values.key_fingerprint || undefined
      };

      const response = await hostsService.createHost(hostData);
      if (response.success && response.data) {
        setHosts(prev => [...prev, { 
          ...response.data!, 
          connectionStatus: 'unknown' 
        }]);
        setShowAddModal(false);
        showSuccess('Host added', `${response.data!.name} has been added successfully`);
        await loadJumpHosts(); // Refresh jump hosts list
      }
    } catch {
      showError('Failed to add host', 'Please check your input and try again');
    } finally {
      setSubmitting(false);
    }
  };

  const handleEditHost = async (values: HostFormData) => {
    if (!selectedHost) return;

    try {
      setSubmitting(true);
      const hostData = {
        ...values,
        port: Number(values.port),
        jump_via: values.jump_via ? Number(values.jump_via) : undefined,
        key_fingerprint: values.key_fingerprint || undefined
      };

      const response = await hostsService.updateHost(selectedHost.name, hostData);
      if (response.success && response.data) {
        setHosts(prev => prev.map(h => 
          h.id === selectedHost.id 
            ? { ...response.data!, connectionStatus: h.connectionStatus, lastTested: h.lastTested }
            : h
        ));
        setShowEditModal(false);
        setSelectedHost(null);
        showSuccess('Host updated', `${response.data!.name} has been updated successfully`);
        await loadJumpHosts(); // Refresh jump hosts list
      }
    } catch {
      showError('Failed to update host', 'Please check your input and try again');
    } finally {
      setSubmitting(false);
    }
  };

  const handleDeleteHost = async () => {
    if (!selectedHost) return;

    try {
      setSubmitting(true);
      const response = await hostsService.deleteHost(selectedHost.name);
      if (response.success) {
        setHosts(prev => prev.filter(h => h.id !== selectedHost.id));
        setShowDeleteModal(false);
        setSelectedHost(null);
        showSuccess('Host deleted', `${selectedHost.name} has been deleted successfully`);
        await loadJumpHosts(); // Refresh jump hosts list
      }
    } catch {
      showError('Failed to delete host', 'Please try again later');
    } finally {
      setSubmitting(false);
    }
  };

  // Table column definitions
  const columns: Column<ExtendedHost>[] = [
    {
      key: 'name',
      header: 'Name',
      sortable: true,
      render: (value) => (
        <div className="font-medium text-gray-900 dark:text-gray-100">
          {value as string}
        </div>
      )
    },
    {
      key: 'address',
      header: 'Address',
      sortable: true,
      render: (value, host) => (
        <div className="text-gray-600 dark:text-gray-400">
          {value as string}:{(host as ExtendedHost).port}
        </div>
      )
    },
    {
      key: 'username',
      header: 'Username',
      sortable: true,
      render: (value) => (
        <code className="text-sm bg-gray-100 dark:bg-gray-800 px-2 py-1 rounded">
          {value as string}
        </code>
      )
    },
    {
      key: 'connectionStatus',
      header: 'Status',
      sortable: true,
      render: (status) => {
        const icons = {
          online: <CheckCircle size={16} className="text-green-500" />,
          offline: <AlertCircle size={16} className="text-red-500" />,
          testing: <Clock size={16} className="text-yellow-500 animate-pulse" />,
          unknown: <Activity size={16} className="text-gray-400" />
        };

        const labels = {
          online: 'Online',
          offline: 'Offline',
          testing: 'Testing...',
          unknown: 'Unknown'
        };

        const colors = {
          online: 'text-green-700 bg-green-50 dark:text-green-400 dark:bg-green-900/20',
          offline: 'text-red-700 bg-red-50 dark:text-red-400 dark:bg-red-900/20',
          testing: 'text-yellow-700 bg-yellow-50 dark:text-yellow-400 dark:bg-yellow-900/20',
          unknown: 'text-gray-700 bg-gray-50 dark:text-gray-400 dark:bg-gray-900/20'
        };

        const currentStatus = (status || 'unknown') as keyof typeof colors;
        return (
          <div className={`inline-flex items-center space-x-1 px-2 py-1 rounded-full text-xs font-medium ${colors[currentStatus]}`}>
            {icons[currentStatus]}
            <span>{labels[currentStatus]}</span>
          </div>
        );
      }
    },
    {
      key: 'jump_via',
      header: 'Jump Host',
      render: (jumpVia) => {
        if (!jumpVia) return <span className="text-gray-400">—</span>;
        const jumpHost = jumpHosts.find(h => h.id === jumpVia);
        return jumpHost ? (
          <span className="text-sm text-gray-600 dark:text-gray-400">
            {jumpHost.name}
          </span>
        ) : (
          <span className="text-gray-400">Unknown</span>
        );
      }
    },
    {
      key: 'actions',
      header: 'Actions',
      render: (_, host) => (
        <div className="flex items-center space-x-2">
          <Button
            variant="ghost"
            size="sm"
            onClick={(e) => {
              e.stopPropagation();
              testConnection(host);
            }}
            disabled={testing[host.id]}
            loading={testing[host.id]}
            title="Test SSH connection"
          >
            <Activity size={16} />
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={(e) => {
              e.stopPropagation();
              setSelectedHost(host);
              setShowEditModal(true);
            }}
            title="Edit host"
          >
            <Edit2 size={16} />
          </Button>
          <Button
            variant="ghost"
            size="sm"
            onClick={(e) => {
              e.stopPropagation();
              setSelectedHost(host);
              setShowDeleteModal(true);
            }}
            title="Delete host"
          >
            <Trash2 size={16} />
          </Button>
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
            <Server size={24} />
            <span>Hosts</span>
          </h1>
          <p className="text-gray-600 dark:text-gray-400">
            Manage SSH hosts and their configurations
          </p>
        </div>
        <Button onClick={() => setShowAddModal(true)} leftIcon={<Plus size={16} />}>
          Add Host
        </Button>
      </div>

      {/* Host List */}
      <Card>
        <CardHeader>
          <CardTitle>SSH Hosts ({hosts.length})</CardTitle>
        </CardHeader>
        <CardContent>
          <DataTable
            data={hosts}
            columns={columns}
            loading={loading}
            emptyMessage="No hosts found. Add your first SSH host to get started."
            searchPlaceholder="Search hosts by name, address, or username..."
            initialSort={{ key: 'name', direction: 'asc' }}
            initialSearch={(location.state as { searchTerm?: string })?.searchTerm || ''}
          />
        </CardContent>
      </Card>

      {/* Add Host Modal */}
      <Modal
        isOpen={showAddModal}
        onClose={() => setShowAddModal(false)}
        title="Add New Host"
        size="lg"
      >
        <Form
          fields={getFormFields(false)}
          onSubmit={(values) => handleAddHost(values as unknown as HostFormData)}
          submitText="Add Host"
          cancelText="Cancel"
          onCancel={() => setShowAddModal(false)}
          loading={submitting}
          layout="grid"
          gridCols={2}
          initialValues={{
            port: 22
          }}
        />
      </Modal>

      {/* Edit Host Modal */}
      <Modal
        isOpen={showEditModal}
        onClose={() => {
          setShowEditModal(false);
          setSelectedHost(null);
        }}
        title="Edit Host"
        size="lg"
      >
        {selectedHost && (
          <Form
            fields={getFormFields(true)}
            onSubmit={(values) => handleEditHost(values as unknown as HostFormData)}
            submitText="Save Changes"
            cancelText="Cancel"
            onCancel={() => {
              setShowEditModal(false);
              setSelectedHost(null);
            }}
            loading={submitting}
            layout="grid"
            gridCols={2}
            initialValues={{
              name: selectedHost.name,
              address: selectedHost.address,
              port: selectedHost.port,
              username: selectedHost.username,
              key_fingerprint: selectedHost.key_fingerprint || '',
              jump_via: selectedHost.jump_via || ''
            }}
          />
        )}
      </Modal>

      {/* Delete Confirmation Modal */}
      <Modal
        isOpen={showDeleteModal}
        onClose={() => {
          setShowDeleteModal(false);
          setSelectedHost(null);
        }}
        title="Delete Host"
        size="md"
      >
        {selectedHost && (
          <div className="space-y-4">
            <div className="flex items-start space-x-3">
              <AlertCircle className="text-red-500 mt-1" size={20} />
              <div>
                <p className="text-gray-900 dark:text-gray-100">
                  Are you sure you want to delete <strong>{selectedHost.name}</strong>?
                </p>
                <p className="text-sm text-gray-600 dark:text-gray-400 mt-1">
                  This action cannot be undone. All authorizations and configurations for this host will be permanently removed.
                </p>
              </div>
            </div>
            
            <div className="bg-gray-50 dark:bg-gray-800 p-3 rounded-md">
              <div className="text-sm space-y-1">
                <div><strong>Name:</strong> {selectedHost.name}</div>
                <div><strong>Address:</strong> {selectedHost.address}:{selectedHost.port}</div>
                <div><strong>Username:</strong> {selectedHost.username}</div>
              </div>
            </div>

            <div className="flex items-center justify-end space-x-3">
              <Button
                variant="secondary"
                onClick={() => {
                  setShowDeleteModal(false);
                  setSelectedHost(null);
                }}
                disabled={submitting}
              >
                Cancel
              </Button>
              <Button
                variant="danger"
                onClick={handleDeleteHost}
                loading={submitting}
              >
                Delete Host
              </Button>
            </div>
          </div>
        )}
      </Modal>
    </div>
  );
};

export default HostsPage;