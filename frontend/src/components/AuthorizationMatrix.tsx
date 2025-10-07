import React, { useState, useMemo, useEffect } from 'react';
import { useNavigate } from 'react-router-dom';
import { Check, X, Loader2, AlertCircle, Eye, EyeOff, Search } from 'lucide-react';
import { cn } from '../utils/cn';
import { User, Host, Authorization } from '../types';
import { Card, CardContent, CardHeader, CardTitle, SearchableSelect } from './ui';
import Button from './ui/Button';
import Input from './ui/Input';

interface AuthorizationMatrixProps {
  users: User[];
  hosts: Host[];
  authorizations: Authorization[];
  onToggleAuthorization: (userId: number, hostId: number, isAuthorized: boolean, loginAccount?: string) => Promise<void>;
  onManageAuthorizations?: (userId: number, hostId: number, authorizations: Authorization[]) => void;
  loading?: boolean;
  className?: string;
  onViewModeChange?: (mode: string) => void; // Callback to change view mode in parent
}

interface MatrixCell {
  userId: number;
  hostId: number;
  authorizations: Authorization[];
  isAuthorized: boolean;
  loading: boolean;
}

const AuthorizationMatrix: React.FC<AuthorizationMatrixProps> = ({
  users,
  hosts,
  authorizations,
  onToggleAuthorization,
  // @ts-expect-error - unused parameter for future extensibility
  onManageAuthorizations, // eslint-disable-line @typescript-eslint/no-unused-vars
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
  const [selectedLoginAccount, setSelectedLoginAccount] = useState<string>('');

  // Restore state from localStorage if returning from navigation
  useEffect(() => {
    const savedState = localStorage.getItem('matrixNavigationState');
    if (savedState) {
      try {
        const state = JSON.parse(savedState);
        setUserSearchTerm(state.userSearchTerm || '');
        setHostSearchTerm(state.hostSearchTerm || '');
        setShowOnlyAuthorized(state.showOnlyAuthorized || false);
        setSelectedLoginAccount(state.selectedLoginAccount || '');

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

  // Collect all unique login accounts from authorizations with counts
  const availableLoginAccounts = useMemo(() => {
    // Count occurrences of each login account
    const loginCounts = new Map<string, number>();
    authorizations.forEach(auth => {
      loginCounts.set(auth.login, (loginCounts.get(auth.login) || 0) + 1);
    });
    
    // Convert to array and sort by count (descending)
    const sortedAccounts = Array.from(loginCounts.entries())
      .sort((a, b) => b[1] - a[1]) // Sort by count descending
      .map(([account]) => account);
    
    // Add "all" at the beginning
    return ['all', ...sortedAccounts];
  }, [authorizations]);

  // Get count for a specific login account
  const getLoginAccountCount = useMemo(() => {
    const counts = new Map<string, number>();
    authorizations.forEach(auth => {
      counts.set(auth.login, (counts.get(auth.login) || 0) + 1);
    });
    return counts;
  }, [authorizations]);

  // Set default login account intelligently
  useEffect(() => {
    if (!selectedLoginAccount && availableLoginAccounts.length > 0) {
      // Try to default to 'root' if it exists, otherwise use first available (most used)
      const hasRoot = availableLoginAccounts.includes('root');
      const defaultAccount = hasRoot ? 'root' : (availableLoginAccounts[1] || availableLoginAccounts[0]); // Skip 'all' at index 0
      setSelectedLoginAccount(defaultAccount);
    }
  }, [selectedLoginAccount, availableLoginAccounts]);

  // Create authorization lookup map - now supports multiple login accounts per user-host
  const authMap = useMemo(() => {
    const map = new Map<string, Authorization[]>();
    authorizations.forEach(auth => {
      const key = `${auth.user_id}-${auth.host_id}`;
      if (!map.has(key)) {
        map.set(key, []);
      }
      map.get(key)!.push(auth);
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
      selectedLoginAccount,
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
      selectedLoginAccount,
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

    // Filter hosts based on selected login account
    if (selectedLoginAccount !== 'all') {
      // Filter hosts to only show those with authorizations for the selected login account
      filteredHosts = filteredHosts.filter(host =>
        authorizations.some(auth => auth.host_id === host.id && auth.login === selectedLoginAccount)
      );
    } else {
      // When "all" is selected, show hosts that have any authorizations
      filteredHosts = filteredHosts.filter(host =>
        authorizations.some(auth => auth.host_id === host.id)
      );
    }

    // Apply "show only authorized" filter if enabled
    if (showOnlyAuthorized) {
      if (selectedLoginAccount !== 'all') {
        // Filter users to only show those with authorizations for the selected login account on the filtered hosts
        filteredUsers = filteredUsers.filter(user =>
          filteredHosts.some(host =>
            authorizations.some(auth => auth.user_id === user.id && auth.host_id === host.id && auth.login === selectedLoginAccount)
          )
        );
      } else {
        // When "all" is selected, show users with any authorizations on the filtered hosts
        filteredUsers = filteredUsers.filter(user =>
          filteredHosts.some(host =>
            authorizations.some(auth => auth.user_id === user.id && auth.host_id === host.id)
          )
        );
      }
    }
    // Otherwise keep all users - this allows seeing which users have access to which relevant hosts

    // Sort filtered data alphabetically
    filteredUsers.sort((a, b) => a.username.localeCompare(b.username));
    filteredHosts.sort((a, b) => a.name.localeCompare(b.name));

    return { filteredUsers, filteredHosts };
  }, [users, hosts, authorizations, showOnlyAuthorized, userSearchTerm, hostSearchTerm, selectedLoginAccount]);

  // Handle cell click to toggle authorization for the selected login account
  const handleCellClick = async (userId: number, hostId: number, isAuthorized: boolean) => {
    // Don't allow clicking when "all" is selected (view-only mode)
    if (selectedLoginAccount === 'all') {
      return;
    }

    const key = `${userId}-${hostId}`;

    // Set loading state
    setCellStates(prev => new Map(prev).set(key, true));

    try {
      await onToggleAuthorization(userId, hostId, isAuthorized, selectedLoginAccount);
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

    if (selectedLoginAccount === 'all') {
      // In "all" mode, show the count of authorizations
      const count = cell.authorizations.length;
      if (count > 0) {
        return <span className="text-sm font-semibold text-green-600 dark:text-green-400">{count}</span>;
      }
      return <span className="text-xs text-gray-400">-</span>;
    }

    if (cell.isAuthorized) {
      // Show checkmark for specific login account
      return <Check size={16} className="text-green-500" />;
    }

    return <X size={16} className="text-gray-400" />;
  };

  // Get cell background color
  const getCellClassName = (cell: MatrixCell, rowIndex: number) => {
    const isHovered = hoveredCell?.userId === cell.userId && hoveredCell?.hostId === cell.hostId;
    const isAllMode = selectedLoginAccount === 'all';
    const hasAuthorizations = cell.authorizations.length > 0;
    
    return cn(
      'w-12 h-8 flex items-center justify-center transition-all duration-150 border border-gray-200 dark:border-gray-700',
      {
        // Cursor style - pointer only when not in "all" mode
        'cursor-pointer': !isAllMode,
        'cursor-default': isAllMode,
        
        // Authorization states
        'bg-green-50 dark:bg-green-900/20': (cell.isAuthorized || (isAllMode && hasAuthorizations)) && !cell.loading,
        'hover:bg-green-100 dark:hover:bg-green-900/30': cell.isAuthorized && !cell.loading && !isAllMode,
        'bg-gray-50 dark:bg-gray-800': (!cell.isAuthorized && !isAllMode) || (isAllMode && !hasAuthorizations) && !cell.loading,
        'hover:bg-gray-100 dark:hover:bg-gray-700': !cell.isAuthorized && !cell.loading && !isAllMode,
        'bg-blue-50 dark:bg-blue-900/20': cell.loading,
        
        // Hover states
        'ring-2 ring-blue-500 ring-opacity-50': isHovered && !isAllMode,
        
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
        <CardTitle>Authorization Matrix</CardTitle>
        
        {/* Search Inputs */}
        <div className="mt-4 space-y-4">
          <div className="flex flex-col sm:flex-row gap-4 max-w-6xl items-end">
            <div className="w-full sm:w-64">
              <Input
                type="text"
                placeholder="Search users by username..."
                value={userSearchTerm}
                onChange={(e) => setUserSearchTerm(e.target.value)}
                leftIcon={<Search size={16} />}
                className="w-full"
              />
            </div>
            <div className="w-full sm:w-64">
              <Input
                type="text"
                placeholder="Search hosts by name or IP..."
                value={hostSearchTerm}
                onChange={(e) => setHostSearchTerm(e.target.value)}
                leftIcon={<Search size={16} />}
                className="w-full"
              />
            </div>
            <div className="w-full sm:w-48">
              <SearchableSelect
                placeholder="Select login account..."
                value={selectedLoginAccount}
                options={availableLoginAccounts.map(account => {
                  if (account === 'all') {
                    return { value: 'all', label: 'all (view only)' };
                  }
                  const count = getLoginAccountCount.get(account) || 0;
                  return { value: account, label: `${account} (${count})` };
                })}
                onValueChange={(value) => setSelectedLoginAccount(value.toString())}
                className="w-full"
              />
            </div>
            <div className="flex-shrink-0">
              <Button
                variant="ghost"
                size="sm"
                onClick={() => setShowOnlyAuthorized(!showOnlyAuthorized)}
                leftIcon={showOnlyAuthorized ? <EyeOff size={16} /> : <Eye size={16} />}
                title={showOnlyAuthorized ? 'Show all users and hosts' : 'Show only users and hosts with authorizations'}
              >
                {showOnlyAuthorized ? 'Show All' : 'Show Authorized Only'}
              </Button>
            </div>
          </div>
          
          {/* Active Filters Indicator */}
          {(userSearchTerm || hostSearchTerm || showOnlyAuthorized) && (
            <div className="flex items-center justify-between p-2 bg-blue-50 dark:bg-blue-900/20 rounded-lg text-sm">
              <div className="flex items-center space-x-2 text-blue-800 dark:text-blue-200">
                <Search size={14} />
                <span>
                  Active filters:
                  {userSearchTerm && ` Users: "${userSearchTerm}"`}
                  {userSearchTerm && (hostSearchTerm || showOnlyAuthorized) && ', '}
                  {hostSearchTerm && ` Hosts: "${hostSearchTerm}"`}
                  {(userSearchTerm || hostSearchTerm) && showOnlyAuthorized && ', '}
                  {showOnlyAuthorized && ' Authorized users only'}
                </span>
              </div>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => {
                  setUserSearchTerm('');
                  setHostSearchTerm('');
                  setShowOnlyAuthorized(false);
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
              {filteredHosts.length === 0
                ? selectedLoginAccount === 'all'
                  ? 'No hosts found with any authorizations.'
                  : 'No hosts found with the selected login account.'
                : filteredUsers.length === 0
                  ? 'No users found matching your criteria.'
                  : 'No data available.'}
              {(userSearchTerm || hostSearchTerm) && ' Try clearing your search filters.'}
              {showOnlyAuthorized && ' Try showing all users.'}
            </p>
          </div>
        ) : (
          <div className="overflow-hidden border border-gray-200 dark:border-gray-700 rounded-lg">
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
                    const userAuthorizations = authMap.get(key) || [];
                    
                    // Filter authorizations based on selected mode
                    const relevantAuthorizations = selectedLoginAccount === 'all' 
                      ? userAuthorizations // Show all authorizations in "all" mode
                      : userAuthorizations.filter(auth => auth.login === selectedLoginAccount);
                    
                    const isAuthorized = relevantAuthorizations.length > 0;
                    const isLoading = cellStates.get(key) || false;

                    const cell: MatrixCell = {
                      userId: user.id,
                      hostId: host.id,
                      authorizations: relevantAuthorizations,
                      isAuthorized,
                      loading: isLoading,
                    };

                    // Build tooltip text
                    let tooltipText = '';
                    if (cell.loading) {
                      tooltipText = 'Updating...';
                    } else if (selectedLoginAccount === 'all') {
                      if (cell.authorizations.length > 0) {
                        const logins = cell.authorizations.map(auth => auth.login).join(', ');
                        tooltipText = `${user.username} on ${host.name}: ${cell.authorizations.length} authorization${cell.authorizations.length > 1 ? 's' : ''} (${logins})`;
                      } else {
                        tooltipText = `${user.username} on ${host.name}: No authorizations`;
                      }
                    } else {
                      tooltipText = cell.isAuthorized
                        ? `${user.username} on ${host.name} as ${selectedLoginAccount}: Authorized${cell.authorizations[0]?.options ? ` (${cell.authorizations[0].options})` : ''}`
                        : `${user.username} on ${host.name} as ${selectedLoginAccount}: Not Authorized`;
                    }

                    return (
                      <div
                        key={`${user.id}-${host.id}`}
                        className={getCellClassName(cell, rowIndex)}
                        onClick={() => !cell.loading && handleCellClick(cell.userId, cell.hostId, cell.isAuthorized)}
                        onMouseEnter={() => selectedLoginAccount !== 'all' && setHoveredCell({ userId: cell.userId, hostId: cell.hostId })}
                        onMouseLeave={() => setHoveredCell(null)}
                        title={tooltipText}
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
          {selectedLoginAccount === 'all' ? (
            <>
              <div className="flex items-center space-x-2">
                <div className="w-6 h-6 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded flex items-center justify-center">
                  <span className="text-xs font-semibold text-green-600 dark:text-green-400">N</span>
                </div>
                <span className="text-gray-900 dark:text-white">Number of authorizations (view only)</span>
              </div>
              <div className="flex items-center space-x-2">
                <div className="w-6 h-6 bg-gray-50 dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded flex items-center justify-center">
                  <span className="text-xs text-gray-400">-</span>
                </div>
                <span className="text-gray-900 dark:text-white">No authorizations</span>
              </div>
            </>
          ) : (
            <>
              <div className="flex items-center space-x-2">
                <div className="w-4 h-4 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded flex items-center justify-center">
                  <Check size={12} className="text-green-500" />
                </div>
                <span className="text-gray-900 dark:text-white">Authorized as {selectedLoginAccount}</span>
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
            </>
          )}
        </div>
      </CardContent>
    </Card>
  );
};

export default AuthorizationMatrix;