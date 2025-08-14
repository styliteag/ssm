import React from 'react';
import { Key } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '../components/ui';

const KeysPage: React.FC = () => {
  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-white flex items-center space-x-2">
            <Key size={24} />
            <span>SSH Keys</span>
          </h1>
          <p className="text-gray-600 dark:text-gray-400">
            Manage SSH public keys for users
          </p>
        </div>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>SSH Key Management</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="text-center py-12">
            <Key size={48} className="mx-auto text-gray-400 dark:text-gray-600" />
            <h3 className="mt-4 text-lg font-medium text-gray-900 dark:text-white">
              SSH Key Management Coming Soon
            </h3>
            <p className="mt-2 text-gray-500 dark:text-gray-400">
              This page will allow you to add, edit, and manage SSH public keys for users.
            </p>
          </div>
        </CardContent>
      </Card>
    </div>
  );
};

export default KeysPage;