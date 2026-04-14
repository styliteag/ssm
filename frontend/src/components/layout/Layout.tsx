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
 GitCompare,
 Activity
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
 {
 label: 'Activities',
 path: '/activities',
 icon: 'Activity',
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
 Activity,
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
 className="fixed inset-0 z-40 bg-black/[0.85] backdrop-blur-sm lg:hidden"
 onClick={() => setSidebarOpen(false)}
 />
 )}

 {/* Sidebar */}
 <div className={`
 fixed inset-y-0 left-0 z-50 w-64 bg-surface-2 border-r border-border transform transition-transform duration-300 ease-in-out lg:relative lg:translate-x-0 lg:flex-shrink-0
 ${sidebarOpen ? 'translate-x-0' : '-translate-x-full'}
 `}>
 <div className="flex items-center justify-between h-16 px-6 border-b border-border">
 <h1 className="text-base font-w590 tracking-h3 text-foreground">
 SSH Key Manager
 </h1>
 <button
 onClick={() => setSidebarOpen(false)}
 className="lg:hidden p-2 cursor-pointer rounded-md text-muted-foreground hover:text-foreground hover:bg-accent transition-colors"
 aria-label="Close sidebar"
 >
 <X size={20} />
 </button>
 </div>

 {/* User info at top of sidebar */}
 <div className="p-4 border-b border-border">
 <div className="flex items-center justify-between">
 <div className="flex items-center space-x-3">
 <div className="w-10 h-10 bg-primary/10 rounded-full flex items-center justify-center">
 <span className="text-sm font-w510 text-primary">
 {username?.charAt(0).toUpperCase()}
 </span>
 </div>
 <div>
 <span className="text-sm font-w510 text-foreground block">
 {username}
 </span>
 <span className="text-xs text-muted-foreground">
 Administrator
 </span>
 </div>
 </div>
 <button
 onClick={toggleTheme}
 className="p-2 cursor-pointer rounded-md text-muted-foreground hover:text-foreground hover:bg-accent transition-colors"
 aria-label={theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'}
 >
 {theme === 'dark' ? <Sun size={18} /> : <Moon size={18} />}
 </button>
 </div>
 </div>

 <nav className="flex-1 mt-4 px-4">
 <ul className="space-y-2">
 {navigationItems.map((item) => {
 const IconComponent = iconComponents[item.icon as keyof typeof iconComponents];
 const isActive = location.pathname === item.path;

 return (
 <li key={item.path}>
 <Link
 to={item.path}
 className={`
 flex items-center px-3 py-2 text-sm font-w510 rounded-md transition-colors cursor-pointer
 ${isActive
 ? 'bg-white/[0.05] text-foreground'
 : 'text-muted-foreground hover:bg-white/[0.02] hover:text-foreground'
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
 {/* Separator and spacing before logout */}
 <li className="pt-4 pb-2">
 <div className="border-t border-border"></div>
 </li>
 {/* Logout button moved up after Users */}
 <li>
 <Button
 variant="ghost"
 size="sm"
 onClick={handleLogout}
 className="w-full justify-start text-muted-foreground hover:text-destructive px-4 py-2 text-sm font-w510 rounded-md transition-colors cursor-pointer"
 leftIcon={<LogOut size={18} />}
 >
 Logout
 </Button>
 </li>
 </ul>
 </nav>
 </div>

 {/* Main content */}
 <div className="flex flex-col min-h-screen lg:flex-1">
 {/* Top bar */}
 <header className="flex-shrink-0 h-16 bg-surface-2 border-b border-border lg:hidden">
 <div className="flex items-center justify-between h-full px-4">
 <button
 onClick={() => setSidebarOpen(true)}
 className="p-2 cursor-pointer rounded-md text-muted-foreground hover:text-foreground hover:bg-accent transition-colors"
 aria-label="Open menu"
 >
 <Menu size={20} />
 </button>
 <h1 className="text-lg font-w590 text-foreground">
 SSH Key Manager
 </h1>
 <button
 onClick={toggleTheme}
 className="p-2 cursor-pointer rounded-md text-muted-foreground hover:text-foreground hover:bg-accent transition-colors"
 aria-label={theme === 'dark' ? 'Switch to light mode' : 'Switch to dark mode'}
 >
 {theme === 'dark' ? <Sun size={20} /> : <Moon size={20} />}
 </button>
 </div>
 </header>

 {/* Page content */}
 <main className="flex-1 p-6 bg-background">
 {children}
 </main>
 </div>
 </div>
 );
};

export default Layout;