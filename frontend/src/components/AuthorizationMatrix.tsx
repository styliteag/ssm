import React, { useState, useMemo, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { Check, X, Loader2, AlertCircle, Eye, EyeOff, Search } from 'lucide-react';
import { cn } from '../utils/cn';
import { User, Host, Authorization } from '../types';
import { Card, CardContent, CardHeader, CardTitle } from './ui';
import Button from './ui/Button';
import Input from './ui/Input';

interface AuthorizationMatrixProps {
  users: User[];
  hosts: Host[];
  authorizations: Authorization[];
  onToggleAuthorization: (userId: number, hostId: number, isAuthorized: boolean) => Promise<void>;
  loading?: boolean;
  className?: string;
  onViewModeChange?: (mode: string) => void; // Callback to change view mode in parent
}

interface MatrixCell {
  userId: number;
  hostId: number;
  authorization?: Authorization;
  isAuthorized: boolean;
  loading: boolean;
}

const AuthorizationMatrix: React.FC<AuthorizationMatrixProps> = ({
  users,
  hosts,
  authorizations,
  onToggleAuthorization,
  loading = false,
  className,
  onViewModeChange,
}) => {
  const navigate = useNavigate();
  const [cellStates, setCellStates] = useState<Map<string, boolean>>(new Map());
  const [hoveredCell, setHoveredCell] = useState<{ userId: number; hostId: number } | null>(null);
  const [showOnlyAuthorized, setShowOnlyAuthorized] = useState(false);
  const [userSearchTerm, setUserSearchTerm] = useState('');
  const [hostSearchTerm, setHostSearchTerm] = useState('');

  // Restore state from localStorage if returning from navigation
  useEffect(() => {
    const savedState = localStorage.getItem('matrixNavigationState');
    if (savedState) {
      try {
        const state = JSON.parse(savedState);
        setUserSearchTerm(state.userSearchTerm || '');
        setHostSearchTerm(state.hostSearchTerm || '');
        setShowOnlyAuthorized(state.showOnlyAuthorized || false);
        
        // Switch to matrix view if needed
        if (state.viewMode === 'matrix' && onViewModeChange) {
          onViewModeChange('matrix');
        }
        
        // Clear the saved state after restoring
        localStorage.removeItem('matrixNavigationState');
      } catch (error) {
        console.error('Error restoring matrix state:', error);
        localStorage.removeItem('matrixNavigationState');
      }
    }
  }, [onViewModeChange]);

  // Create authorization lookup map
  const authMap = useMemo(() => {
    const map = new Map<string, Authorization>();
    authorizations.forEach(auth => {
      map.set(`${auth.user_id}-${auth.host_id}`, auth);
    });
    return map;
  }, [authorizations]);

  // Navigation handlers
  const handleUserClick = (username: string) => {
    // Save current state to localStorage for back navigation
    const matrixState = {
      userSearchTerm,
      hostSearchTerm,
      showOnlyAuthorized,
    };
    localStorage.setItem('matrixNavigationState', JSON.stringify(matrixState));
    navigate('/users', { state: { searchTerm: username } });
  };

  const handleHostClick = (hostname: string) => {
    // Save current state to localStorage for back navigation
    const matrixState = {
      userSearchTerm,
      hostSearchTerm,
      showOnlyAuthorized,
    };
    localStorage.setItem('matrixNavigationState', JSON.stringify(matrixState));
    navigate('/hosts', { state: { searchTerm: hostname } });
  };

  // Filter data based on show only authorized and search terms
  const { filteredUsers, filteredHosts } = useMemo(() => {
    let filteredUsers = users;
    let filteredHosts = hosts;
    
    // Filter users by search term
    if (userSearchTerm.trim()) {
      const searchLower = userSearchTerm.toLowerCase();
      filteredUsers = filteredUsers.filter(user => 
        user.username.toLowerCase().includes(searchLower)
      );
    }
    
    // Filter hosts by search term
    if (hostSearchTerm.trim()) {
      const searchLower = hostSearchTerm.toLowerCase();
      filteredHosts = filteredHosts.filter(host => 
        host.name.toLowerCase().includes(searchLower) || 
        host.address.toLowerCase().includes(searchLower)
      );
    }
    
    // Filter by authorized only
    if (showOnlyAuthorized) {
      filteredUsers = filteredUsers.filter(user => 
        filteredHosts.some(host => 
          authorizations.some(auth => auth.user_id === user.id && auth.host_id === host.id)
        )
      );
      
      filteredHosts = filteredHosts.filter(host =>
        filteredUsers.some(user =>
          authorizations.some(auth => auth.user_id === user.id && auth.host_id === host.id)
        )
      );
    }
    
    return { filteredUsers, filteredHosts };
  }, [users, hosts, authorizations, showOnlyAuthorized, userSearchTerm, hostSearchTerm]);

  // Handle cell click to toggle authorization
  const handleCellClick = async (userId: number, hostId: number, isAuthorized: boolean) => {
    const key = `${userId}-${hostId}`;
    
    // Set loading state
    setCellStates(prev => new Map(prev).set(key, true));
    
    try {
      await onToggleAuthorization(userId, hostId, isAuthorized);
    } catch (error) {
      console.error('Failed to toggle authorization:', error);
    } finally {
      // Clear loading state
      setCellStates(prev => {
        const newMap = new Map(prev);
        newMap.delete(key);
        return newMap;
      });
    }
  };


  // Get cell content based on state
  const getCellContent = (cell: MatrixCell) => {
    if (cell.loading) {
      return <Loader2 size={16} className="animate-spin text-blue-500" />;
    }
    
    if (cell.isAuthorized) {
      return <Check size={16} className="text-green-500" />;
    }
    
    return <X size={16} className="text-gray-400" />;
  };

  // Get cell background color
  const getCellClassName = (cell: MatrixCell, rowIndex: number) => {
    const isHovered = hoveredCell?.userId === cell.userId && hoveredCell?.hostId === cell.hostId;
    
    return cn(
      'w-12 h-8 flex items-center justify-center cursor-pointer transition-all duration-150 border border-gray-200 dark:border-gray-700',
      {
        // Authorization states
        'bg-green-50 dark:bg-green-900/20 hover:bg-green-100 dark:hover:bg-green-900/30': cell.isAuthorized && !cell.loading,
        'bg-gray-50 dark:bg-gray-800 hover:bg-gray-100 dark:hover:bg-gray-700': !cell.isAuthorized && !cell.loading,
        'bg-blue-50 dark:bg-blue-900/20': cell.loading,
        
        // Hover states
        'ring-2 ring-blue-500 ring-opacity-50': isHovered,
        
        // Zebra striping
        'bg-opacity-80': rowIndex % 2 === 0,
      }
    );
  };

  // Truncate text for labels
  const truncateText = (text: string, maxLength: number = 12) => {
    return text.length > maxLength ? `${text.substring(0, maxLength)}...` : text;
  };

  if (loading) {
    return (
      <Card className={className}>
        <CardContent className="flex items-center justify-center py-12">
          <div className="flex items-center space-x-2">
            <Loader2 className="h-6 w-6 animate-spin" />
            <span className="text-gray-900 dark:text-white">Loading authorization matrix...</span>
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className={className}>
      <CardHeader>
        <div className="flex items-center justify-between">
          <CardTitle>Authorization Matrix</CardTitle>
          <div className="flex items-center space-x-2">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setShowOnlyAuthorized(!showOnlyAuthorized)}
              leftIcon={showOnlyAuthorized ? <EyeOff size={16} /> : <Eye size={16} />}
            >
              {showOnlyAuthorized ? 'Show All' : 'Show Authorized Only'}
            </Button>
          </div>
        </div>
        
        {/* Search Inputs */}
        <div className="mt-4 space-y-4">
          <div className="flex flex-col sm:flex-row gap-4 max-w-3xl">
            <div className="w-full sm:w-80">
              <Input
                type="text"
                placeholder="Search users by username..."
                value={userSearchTerm}
                onChange={(e) => setUserSearchTerm(e.target.value)}
                leftIcon={<Search size={16} />}
                className="w-full"
              />
            </div>
            <div className="w-full sm:w-80">
              <Input
                type="text"
                placeholder="Search hosts by name or IP..."
                value={hostSearchTerm}
                onChange={(e) => setHostSearchTerm(e.target.value)}
                leftIcon={<Search size={16} />}
                className="w-full"
              />
            </div>
          </div>
          
          {/* Active Filters Indicator */}
          {(userSearchTerm || hostSearchTerm) && (
            <div className="flex items-center justify-between p-2 bg-blue-50 dark:bg-blue-900/20 rounded-lg text-sm">
              <div className="flex items-center space-x-2 text-blue-800 dark:text-blue-200">
                <Search size={14} />
                <span>
                  Active filters: 
                  {userSearchTerm && ` Users: "${userSearchTerm}"`}
                  {userSearchTerm && hostSearchTerm && ', '}
                  {hostSearchTerm && ` Hosts: "${hostSearchTerm}"`}
                </span>
              </div>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => {
                  setUserSearchTerm('');
                  setHostSearchTerm('');
                }}
                className="text-blue-600 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-200"
              >
                Clear All
              </Button>
            </div>
          )}
        </div>
        
      </CardHeader>
      
      <CardContent>
        {filteredUsers.length === 0 || filteredHosts.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-12">
            <AlertCircle className="h-12 w-12 text-gray-400 mb-4" />
            <h3 className="text-lg font-medium text-gray-900 dark:text-white mb-2">
              No Data Available
            </h3>
            <p className="text-gray-500 dark:text-gray-400 text-center">
              {filteredUsers.length === 0 && filteredHosts.length === 0 
                ? 'No users or hosts match your search criteria.' 
                : filteredUsers.length === 0 
                  ? 'No users found matching your search.' 
                  : 'No hosts found matching your search.'}
              {showOnlyAuthorized && ' Try showing all users and hosts.'}
              {(userSearchTerm || hostSearchTerm) && ' Try clearing your search filters.'}
            </p>
          </div>
        ) : (
          <div className="overflow-auto max-h-[600px] border border-gray-200 dark:border-gray-700 rounded-lg">
            <div className="min-w-max">
              {/* Header with host names */}
              <div className="flex bg-gray-50 dark:bg-gray-800 sticky top-0 z-10">
                <div className="w-40 h-16 flex items-center px-3 border-r border-gray-200 dark:border-gray-700 font-medium text-sm text-gray-900 dark:text-white">
                  Users / Hosts
                </div>
                {filteredHosts.map((host) => (
                  <div
                    key={host.id}
                    className="w-12 h-16 flex items-center justify-center border-r border-gray-200 dark:border-gray-700 cursor-pointer hover:bg-blue-50 dark:hover:bg-blue-900/20 transition-colors relative overflow-hidden"
                    title={`${host.name} (${host.address}) - Click to navigate to hosts page`}
                    onClick={() => handleHostClick(host.name)}
                  >
                    <span className="text-xs font-medium transform -rotate-45 origin-center whitespace-nowrap text-gray-900 dark:text-white absolute hover:text-blue-600 dark:hover:text-blue-400 transition-colors">
                      {truncateText(host.name, 10)}
                    </span>
                  </div>
                ))}
              </div>

              {/* Matrix rows */}
              {filteredUsers.map((user, rowIndex) => (
                <div key={user.id} className="flex">
                  {/* User name column */}
                  <div
                    className={cn(
                      'w-40 h-8 flex items-center px-3 border-r border-b border-gray-200 dark:border-gray-700 text-sm cursor-pointer hover:bg-blue-50 dark:hover:bg-blue-900/20 transition-colors',
                      !user.enabled && 'text-gray-400 dark:text-gray-500 italic'
                    )}
                    title={`${user.username}${!user.enabled ? ' (disabled)' : ''} - Click to navigate to users page`}
                    onClick={() => handleUserClick(user.username)}
                  >
                    <span className="truncate text-gray-900 dark:text-white hover:text-blue-600 dark:hover:text-blue-400 transition-colors">
                      {truncateText(user.username, 16)}
                      {!user.enabled && ' (disabled)'}
                    </span>
                  </div>

                  {/* Authorization cells */}
                  {filteredHosts.map((host) => {
                    const key = `${user.id}-${host.id}`;
                    const authorization = authMap.get(key);
                    const isAuthorized = !!authorization;
                    const isLoading = cellStates.get(key) || false;
                    
                    const cell: MatrixCell = {
                      userId: user.id,
                      hostId: host.id,
                      authorization,
                      isAuthorized,
                      loading: isLoading,
                    };

                    return (
                      <div
                        key={`${user.id}-${host.id}`}
                        className={getCellClassName(cell, rowIndex)}
                        onClick={() => !cell.loading && handleCellClick(cell.userId, cell.hostId, cell.isAuthorized)}
                        onMouseEnter={() => setHoveredCell({ userId: cell.userId, hostId: cell.hostId })}
                        onMouseLeave={() => setHoveredCell(null)}
                        title={
                          cell.loading 
                            ? 'Updating...' 
                            : `${user.username} on ${host.name}: ${cell.isAuthorized ? 'Authorized' : 'Not Authorized'}${cell.authorization?.login ? ` (login: ${cell.authorization.login})` : ''}`
                        }
                      >
                        {getCellContent(cell)}
                      </div>
                    );
                  })}
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Legend */}
        <div className="flex items-center justify-center space-x-6 mt-4 text-sm">
          <div className="flex items-center space-x-2">
            <div className="w-4 h-4 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded flex items-center justify-center">
              <Check size={12} className="text-green-500" />
            </div>
            <span className="text-gray-900 dark:text-white">Authorized</span>
          </div>
          <div className="flex items-center space-x-2">
            <div className="w-4 h-4 bg-gray-50 dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded flex items-center justify-center">
              <X size={12} className="text-gray-400" />
            </div>
            <span className="text-gray-900 dark:text-white">Not Authorized</span>
          </div>
          <div className="flex items-center space-x-2">
            <div className="w-4 h-4 bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded flex items-center justify-center">
              <Loader2 size={12} className="text-blue-500" />
            </div>
            <span className="text-gray-900 dark:text-white">Updating</span>
          </div>
        </div>
      </CardContent>
    </Card>
  );
};

export default AuthorizationMatrix;