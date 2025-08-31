import React from 'react';
import { BrowserRouter as Router, Routes, Route, Navigate } from 'react-router-dom';
import { AuthProvider, useAuth } from './contexts/AuthContext';
import { ThemeProvider } from './contexts/ThemeContext';
import { NotificationProvider } from './contexts/NotificationContext';

// Pages
import LoginPage from './pages/LoginPage';
import DashboardPage from './pages/DashboardPage';
import HostsPage from './pages/HostsPage';
import UsersPage from './pages/UsersPage';
import KeysPage from './pages/KeysPage';
import AuthorizationsPage from './pages/AuthorizationsPage';
import DiffPage from './pages/DiffPage';

// Components
import Layout from './components/layout/Layout';
import NotificationToast from './components/shared/NotificationToast';
import { Loading } from './components/ui';

// Protected Route Component
const ProtectedRoute: React.FC<{ children: React.ReactNode }> = ({ children }) => {
  const { isAuthenticated, isLoading } = useAuth();

  if (isLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <Loading size="lg" text="Loading..." />
      </div>
    );
  }

  return isAuthenticated ? <>{children}</> : <Navigate to="/login" replace />;
};

// App Router Component
const AppRouter: React.FC = () => {
  return (
    <Router>
      <Routes>
        {/* Public routes */}
        <Route path="/login" element={<LoginPage />} />
        
        {/* Protected routes */}
        <Route path="/" element={
          <ProtectedRoute>
            <Layout>
              <DashboardPage />
            </Layout>
          </ProtectedRoute>
        } />
        
        <Route path="/dashboard" element={
          <ProtectedRoute>
            <Layout>
              <DashboardPage />
            </Layout>
          </ProtectedRoute>
        } />
        
        <Route path="/hosts" element={
          <ProtectedRoute>
            <Layout>
              <HostsPage />
            </Layout>
          </ProtectedRoute>
        } />
        
        <Route path="/users" element={
          <ProtectedRoute>
            <Layout>
              <UsersPage />
            </Layout>
          </ProtectedRoute>
        } />
        
        <Route path="/keys" element={
          <ProtectedRoute>
            <Layout>
              <KeysPage />
            </Layout>
          </ProtectedRoute>
        } />
        
        <Route path="/authorizations" element={
          <ProtectedRoute>
            <Layout>
              <AuthorizationsPage />
            </Layout>
          </ProtectedRoute>
        } />
        
        <Route path="/diff" element={
          <ProtectedRoute>
            <Layout>
              <DiffPage />
            </Layout>
          </ProtectedRoute>
        } />

        {/* Redirect unknown routes to dashboard */}
        <Route path="*" element={<Navigate to="/dashboard" replace />} />
      </Routes>
    </Router>
  );
};

// Main App Component
const App: React.FC = () => {
  return (
    <ThemeProvider>
      <NotificationProvider>
        <AuthProvider>
          <div className="min-h-screen bg-gray-50 dark:bg-gray-900">
            <AppRouter />
            <NotificationToast />
          </div>
        </AuthProvider>
      </NotificationProvider>
    </ThemeProvider>
  );
};

export default App;
