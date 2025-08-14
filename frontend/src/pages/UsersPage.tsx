import React from 'react';
import { Users } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '../components/ui';

const UsersPage: React.FC = () => {
  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white flex items-center space-x-2">
            <Users size={24} />
            <span>Users</span>
          </h1>
          <p className="text-gray-600 dark:text-gray-400">
            Manage users and their access permissions
          </p>
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>User Management</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="text-center py-12">
            <Users size={48} className="mx-auto text-gray-400 dark:text-gray-600" />
            <h3 className="mt-4 text-lg font-medium text-gray-900 dark:text-white">
              User Management Coming Soon
            </h3>
            <p className="mt-2 text-gray-500 dark:text-gray-400">
              This page will allow you to add, edit, and manage users and their permissions.
            </p>
          </div>
        </CardContent>
      </Card>
    </div>
  );
};

export default UsersPage;