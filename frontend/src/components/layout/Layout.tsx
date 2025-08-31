import React, { useState } from 'react';
import { Link, useLocation } from 'react-router-dom';
import { 
  Server, 
  Users, 
  Key, 
  Shield, 
  LayoutDashboard, 
  Menu, 
  X, 
  LogOut,
  Sun,
  Moon,
  GitCompare
} from 'lucide-react';
import { useAuth } from '../../contexts/AuthContext';
import { useTheme } from '../../contexts/ThemeContext';
import { Button } from '../ui';
import { NavigationItem } from '../../types';

interface LayoutProps {
  children: React.ReactNode;
}

const navigationItems: NavigationItem[] = [
  {
    label: 'Dashboard',
    path: '/dashboard',
    icon: 'LayoutDashboard',
    requiresAuth: true,
  },
  {
    label: 'Hosts',
    path: '/hosts',
    icon: 'Server',
    requiresAuth: true,
  },
  {
    label: 'Users',
    path: '/users',
    icon: 'Users',
    requiresAuth: true,
  },
  {
    label: 'SSH Keys',
    path: '/keys',
    icon: 'Key',
    requiresAuth: true,
  },
  {
    label: 'Authorizations',
    path: '/authorizations',
    icon: 'Shield',
    requiresAuth: true,
  },
  {
    label: 'Diff Viewer',
    path: '/diff',
    icon: 'GitCompare',
    requiresAuth: true,
  },
];

const iconComponents = {
  LayoutDashboard,
  Server,
  Users,
  Key,
  Shield,
  GitCompare,
};

const Layout: React.FC<LayoutProps> = ({ children }) => {
  const [sidebarOpen, setSidebarOpen] = useState(false);
  const { logout, username } = useAuth();
  const { theme, toggleTheme } = useTheme();
  const location = useLocation();

  const handleLogout = async () => {
    try {
      await logout();
    } catch (error) {
      console.error('Logout failed:', error);
    }
  };

  return (
    <div className="min-h-screen lg:flex">
      {/* Mobile sidebar overlay */}
      {sidebarOpen && (
        <div
          className="fixed inset-0 z-40 bg-black bg-opacity-50 lg:hidden"
          onClick={() => setSidebarOpen(false)}
        />
      )}

      {/* Sidebar */}
      <div className={`
        fixed inset-y-0 left-0 z-50 w-64 bg-white dark:bg-gray-800 shadow-lg transform transition-transform duration-300 ease-in-out lg:relative lg:translate-x-0 lg:flex-shrink-0
        ${sidebarOpen ? 'translate-x-0' : '-translate-x-full'}
      `}>
        <div className="flex items-center justify-between h-16 px-6 border-b border-gray-200 dark:border-gray-700">
          <h1 className="text-xl font-bold text-gray-900 dark:text-white">
            SSH Key Manager
          </h1>
          <button
            onClick={() => setSidebarOpen(false)}
            className="lg:hidden text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
          >
            <X size={20} />
          </button>
        </div>

        {/* User info at top of sidebar */}
        <div className="p-4 border-b border-gray-200 dark:border-gray-700">
          <div className="flex items-center justify-between">
            <div className="flex items-center space-x-3">
              <div className="w-10 h-10 bg-blue-100 dark:bg-blue-900 rounded-full flex items-center justify-center">
                <span className="text-sm font-medium text-blue-600 dark:text-blue-300">
                  {username?.charAt(0).toUpperCase()}
                </span>
              </div>
              <div>
                <span className="text-sm font-medium text-gray-900 dark:text-white block">
                  {username}
                </span>
                <span className="text-xs text-gray-500 dark:text-gray-400">
                  Administrator
                </span>
              </div>
            </div>
            <button
              onClick={toggleTheme}
              className="p-2 text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200 rounded-md hover:bg-gray-100 dark:hover:bg-gray-800"
            >
              {theme === 'dark' ? <Sun size={18} /> : <Moon size={18} />}
            </button>
          </div>
        </div>

        <nav className="flex-1 mt-4 px-4 pb-20">
          <ul className="space-y-2">
            {navigationItems.map((item) => {
              const IconComponent = iconComponents[item.icon as keyof typeof iconComponents];
              const isActive = location.pathname === item.path;
              
              return (
                <li key={item.path}>
                  <Link
                    to={item.path}
                    className={`
                      flex items-center px-4 py-2 text-sm font-medium rounded-md transition-colors
                      ${isActive
                        ? 'bg-blue-100 text-blue-700 dark:bg-blue-900/50 dark:text-blue-200'
                        : 'text-gray-600 hover:bg-gray-50 hover:text-gray-900 dark:text-gray-300 dark:hover:bg-gray-700 dark:hover:text-white'
                      }
                    `}
                    onClick={() => setSidebarOpen(false)}
                  >
                    <IconComponent size={18} className="mr-3" />
                    {item.label}
                  </Link>
                </li>
              );
            })}
          </ul>
        </nav>

        {/* Logout at bottom */}
        <div className="absolute bottom-0 left-0 right-0 p-4">
          <Button
            variant="ghost"
            size="sm"
            onClick={handleLogout}
            className="w-full justify-start text-gray-600 hover:text-red-600 dark:text-gray-400 dark:hover:text-red-400"
            leftIcon={<LogOut size={16} />}
          >
            Logout
          </Button>
        </div>
      </div>

      {/* Main content */}
      <div className="flex flex-col min-h-screen lg:flex-1">
        {/* Top bar */}
        <header className="flex-shrink-0 h-16 bg-white dark:bg-gray-800 shadow-sm border-b border-gray-200 dark:border-gray-700 lg:hidden">
          <div className="flex items-center justify-between h-full px-4">
            <button
              onClick={() => setSidebarOpen(true)}
              className="text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200 p-2"
            >
              <Menu size={20} />
            </button>
            <h1 className="text-lg font-semibold text-gray-900 dark:text-white">
              SSH Key Manager
            </h1>
            <button
              onClick={toggleTheme}
              className="p-2 text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
            >
              {theme === 'dark' ? <Sun size={20} /> : <Moon size={20} />}
            </button>
          </div>
        </header>

        {/* Page content */}
        <main className="flex-1 p-6 bg-gray-50 dark:bg-gray-900">
          {children}
        </main>
      </div>
    </div>
  );
};

export default Layout;