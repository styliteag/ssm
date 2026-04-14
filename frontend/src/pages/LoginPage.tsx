import React, { useState } from 'react';
import { Navigate, useNavigate } from 'react-router-dom';
import { Key, Sun, Moon, ShieldCheck, Lock, Zap } from 'lucide-react';
import { useAuth } from '../contexts/AuthContext';
import { useTheme } from '../contexts/ThemeContext';
import { useNotifications } from '../contexts/NotificationContext';
import { Button, Input, Card, CardHeader, CardContent } from '../components/ui';

// Vite replaces `import.meta.env.DEV` with a literal `true` / `false` at build
// time — anything gated on it is dead-code-eliminated from production bundles.
// `npm run build` → DEV === false → the dev-login branch never ships.
const IS_DEV = import.meta.env.DEV;
const DEV_USERNAME = (import.meta.env.VITE_DEV_USERNAME as string | undefined) || 'admin';
const DEV_PASSWORD = (import.meta.env.VITE_DEV_PASSWORD as string | undefined) || 'admin';

const LoginPage: React.FC = () => {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [isLoading, setIsLoading] = useState(false);

  const { login, isAuthenticated } = useAuth();
  const { theme, toggleTheme } = useTheme();
  const { showError } = useNotifications();
  const navigate = useNavigate();

  // Redirect if already authenticated
  if (isAuthenticated) {
    return <Navigate to="/dashboard" replace />;
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!username.trim() || !password.trim()) {
      showError('Login Failed', 'Please enter both username and password');
      return;
    }

    setIsLoading(true);

    try {
      const success = await login({ username: username.trim(), password });
      if (success) {
        navigate('/dashboard');
      }
    } catch (error: unknown) {
      showError('Login Failed', (error as { message?: string })?.message || 'Invalid username or password');
    } finally {
      setIsLoading(false);
    }
  };

  // Dev-only: one-click login as the seeded admin user.
  // The whole function and its caller are tree-shaken when IS_DEV is false.
  const handleDevLogin = async () => {
    setIsLoading(true);
    try {
      const success = await login({ username: DEV_USERNAME, password: DEV_PASSWORD });
      if (success) {
        navigate('/dashboard');
      } else {
        showError(
          'Dev login failed',
          `Could not sign in as ${DEV_USERNAME}. Seed the dev .htpasswd or set VITE_DEV_USERNAME / VITE_DEV_PASSWORD.`,
        );
      }
    } catch (error: unknown) {
      showError('Dev login failed', (error as { message?: string })?.message || 'Unknown error');
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <div className="min-h-screen w-full flex items-center justify-center relative overflow-hidden bg-background">
      {/* Subtle Linear-style indigo halo — single accent, not competing gradients */}
      <div className="absolute inset-0 overflow-hidden pointer-events-none">
        <div className="absolute top-[30%] left-1/2 -translate-x-1/2 w-[600px] h-[600px] rounded-full bg-primary/10 blur-[140px]" />
      </div>

      {/* Theme Toggle — ghost button in Linear style */}
      <div className="absolute top-6 right-6 z-20">
        <button
          onClick={toggleTheme}
          className="p-2.5 cursor-pointer rounded-md bg-white/[0.02] border border-border hover:bg-white/[0.05] transition-colors text-muted-foreground hover:text-foreground"
          aria-label="Toggle theme"
        >
          {theme === 'dark' ? <Sun size={18} /> : <Moon size={18} />}
        </button>
      </div>

      <div className="w-full max-w-[400px] px-4 z-10">
        <div className="text-center mb-10">
          <div className="relative inline-flex mb-8">
            <div className="h-12 w-12 bg-primary rounded-lg flex items-center justify-center">
              <Key className="h-6 w-6 text-primary-foreground" />
            </div>
            <div className="absolute -bottom-1 -right-1 bg-surface-3 rounded-full p-1 border border-border">
              <ShieldCheck className="h-3 w-3 text-success" />
            </div>
          </div>

          <h1 className="text-[48px] leading-[1] font-w510 tracking-display text-foreground mb-3">
            Welcome back
          </h1>
          <p className="text-muted-foreground text-[15px] tracking-body-lg">
            Secure SSH Key Management
          </p>
        </div>

        <Card variant="default" className="bg-white/[0.02]">
          <CardHeader className="pb-3">
            <div className="flex items-center justify-center space-x-2 text-xs text-muted-foreground">
              <Lock className="w-3.5 h-3.5" />
              <span className="font-w510">Secure Login</span>
            </div>
          </CardHeader>
          <CardContent>
            <form onSubmit={handleSubmit} className="space-y-5">
              <div className="space-y-4">
                <Input
                  label="Username"
                  type="text"
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  placeholder="admin"
                  required
                  autoComplete="username"
                  disabled={isLoading}
                />

                <Input
                  label="Password"
                  type="password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="••••••••"
                  required
                  autoComplete="current-password"
                  disabled={isLoading}
                />
              </div>

              <Button
                type="submit"
                variant="primary"
                className="w-full"
                loading={isLoading}
                disabled={isLoading || !username.trim() || !password.trim()}
              >
                Sign in
              </Button>

              {IS_DEV && (
                <div className="pt-2 border-t border-dashed border-warning/40">
                  <Button
                    type="button"
                    variant="secondary"
                    className="w-full"
                    loading={isLoading}
                    disabled={isLoading}
                    onClick={handleDevLogin}
                  >
                    <Zap className="w-4 h-4 mr-2" />
                    Dev login ({DEV_USERNAME})
                  </Button>
                  <p className="mt-2 text-[10px] text-warning text-center uppercase tracking-wider font-w510">
                    Dev build only — removed from production bundles
                  </p>
                </div>
              )}
            </form>
          </CardContent>
        </Card>

        <div className="mt-8 text-center">
          <p className="text-xs text-muted-foreground/60 font-w510">
            Secure SSH Manager v1.0.0 • Encrypted Connection
          </p>
        </div>
      </div>
    </div>
  );
};

export default LoginPage;