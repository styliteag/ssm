import React, { useState } from 'react';
import { Navigate, useNavigate } from 'react-router-dom';
import { Key, Sun, Moon, ShieldCheck, Lock } from 'lucide-react';
import { useAuth } from '../contexts/AuthContext';
import { useTheme } from '../contexts/ThemeContext';
import { useNotifications } from '../contexts/NotificationContext';
import { Button, Input, Card, CardHeader, CardContent } from '../components/ui';

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

  return (
    <div className="min-h-screen w-full flex items-center justify-center relative overflow-hidden bg-background transition-colors duration-500">
      {/* Animated Background Gradients */}
      <div className="absolute inset-0 overflow-hidden pointer-events-none">
        <div className="absolute -top-[20%] -left-[10%] w-[70%] h-[70%] rounded-full bg-primary/20 blur-[120px] animate-pulse-slow" />
        <div className="absolute top-[40%] -right-[10%] w-[60%] h-[60%] rounded-full bg-secondary/20 blur-[100px] animate-pulse-slow delay-1000" />
        <div className="absolute -bottom-[20%] left-[20%] w-[50%] h-[50%] rounded-full bg-accent/20 blur-[120px] animate-pulse-slow delay-2000" />
      </div>

      {/* Theme Toggle */}
      <div className="absolute top-6 right-6 z-20 animate-in slide-in-from-top-4 fade-in duration-700">
        <button
          onClick={toggleTheme}
          className="p-3 rounded-full bg-white/10 backdrop-blur-md border border-white/20 shadow-lg hover:bg-white/20 transition-all duration-300 text-foreground"
          aria-label="Toggle theme"
        >
          {theme === 'dark' ? <Sun size={20} className="text-yellow-400" /> : <Moon size={20} className="text-slate-700" />}
        </button>
      </div>

      <div className="w-full max-w-md px-4 z-10">
        <div className="text-center mb-8 animate-in slide-in-from-bottom-8 fade-in duration-700">
          <div className="relative inline-block mb-6">
            <div className="absolute inset-0 bg-primary/30 blur-xl rounded-full animate-pulse-slow" />
            <div className="relative h-20 w-20 mx-auto bg-gradient-to-br from-primary to-primary-600 rounded-2xl flex items-center justify-center shadow-2xl transform rotate-3 hover:rotate-6 transition-transform duration-300">
              <Key className="h-10 w-10 text-white drop-shadow-md" />
            </div>
            <div className="absolute -bottom-2 -right-2 bg-background rounded-full p-1.5 shadow-lg border border-border">
              <ShieldCheck className="h-5 w-5 text-success" />
            </div>
          </div>

          <h1 className="text-4xl font-bold tracking-tight text-foreground mb-2">
            Welcome Back
          </h1>
          <p className="text-muted-foreground text-lg">
            Secure SSH Key Management
          </p>
        </div>

        <Card variant="glass" className="animate-in slide-in-from-bottom-4 fade-in duration-700 delay-150">
          <CardHeader className="pb-2">
            <div className="flex items-center justify-center space-x-2 text-sm text-muted-foreground mb-2">
              <Lock className="w-4 h-4" />
              <span>Secure Login</span>
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
                  className="bg-white/50 dark:bg-gray-900/50 backdrop-blur-sm"
                />

                <div className="space-y-1">
                  <Input
                    label="Password"
                    type="password"
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    placeholder="••••••••"
                    required
                    autoComplete="current-password"
                    disabled={isLoading}
                    className="bg-white/50 dark:bg-gray-900/50 backdrop-blur-sm"
                  />
                  <div className="flex justify-end">
                    <a href="#" className="text-xs font-medium text-primary hover:text-primary/80 transition-colors">
                      Forgot password?
                    </a>
                  </div>
                </div>
              </div>

              <Button
                type="submit"
                variant="gradient"
                className="w-full h-11 text-base font-semibold shadow-lg shadow-primary/25"
                loading={isLoading}
                disabled={isLoading || !username.trim() || !password.trim()}
              >
                Sign In
              </Button>
            </form>
          </CardContent>
        </Card>

        <div className="mt-8 text-center animate-in fade-in duration-700 delay-300">
          <p className="text-xs text-muted-foreground/60 font-medium">
            Secure SSH Manager v1.0.0 • Encrypted Connection
          </p>
        </div>
      </div>
    </div>
  );
};

export default LoginPage;