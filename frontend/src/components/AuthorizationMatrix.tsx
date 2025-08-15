import React, { useState, useMemo } from 'react';
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
}) => {
  const [cellStates, setCellStates] = useState<Map<string, boolean>>(new Map());
  const [hoveredCell, setHoveredCell] = useState<{ userId: number; hostId: number } | null>(null);
  const [selectedUsers, setSelectedUsers] = useState<Set<number>>(new Set());
  const [selectedHosts, setSelectedHosts] = useState<Set<number>>(new Set());
  const [showOnlyAuthorized, setShowOnlyAuthorized] = useState(false);
  const [searchTerm, setSearchTerm] = useState('');

  // Create matrix data structure
  const matrixData = useMemo(() => {
    const matrix: MatrixCell[][] = [];
    const authMap = new Map<string, Authorization>();
    
    // Create authorization lookup map
    authorizations.forEach(auth => {
      authMap.set(`${auth.user_id}-${auth.host_id}`, auth);
    });

    users.forEach(user => {
      const row: MatrixCell[] = [];
      hosts.forEach(host => {
        const key = `${user.id}-${host.id}`;
        const authorization = authMap.get(key);
        const isLoading = cellStates.get(key) || false;
        
        row.push({
          userId: user.id,
          hostId: host.id,
          authorization,
          isAuthorized: !!authorization,
          loading: isLoading,
        });
      });
      matrix.push(row);
    });

    return matrix;
  }, [users, hosts, authorizations, cellStates]);

  // Filter data based on show only authorized and search term
  const filteredUsers = useMemo(() => {
    let filtered = users;
    
    // Filter by search term
    if (searchTerm.trim()) {
      const searchLower = searchTerm.toLowerCase();
      filtered = filtered.filter(user => 
        user.username.toLowerCase().includes(searchLower)
      );
    }
    
    // Filter by authorized only
    if (showOnlyAuthorized) {
      filtered = filtered.filter(user => 
        hosts.some(host => 
          authorizations.some(auth => auth.user_id === user.id && auth.host_id === host.id)
        )
      );
    }
    
    return filtered;
  }, [users, hosts, authorizations, showOnlyAuthorized, searchTerm]);

  const filteredHosts = useMemo(() => {
    let filtered = hosts;
    
    // Filter by search term
    if (searchTerm.trim()) {
      const searchLower = searchTerm.toLowerCase();
      filtered = filtered.filter(host => 
        host.name.toLowerCase().includes(searchLower) || 
        host.address.toLowerCase().includes(searchLower)
      );
    }
    
    // Filter by authorized only
    if (showOnlyAuthorized) {
      filtered = filtered.filter(host =>
        users.some(user =>
          authorizations.some(auth => auth.user_id === user.id && auth.host_id === host.id)
        )
      );
    }
    
    return filtered;
  }, [users, hosts, authorizations, showOnlyAuthorized, searchTerm]);

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

  // Handle bulk operations
  const handleBulkGrantAccess = async (userIds: number[], hostIds: number[]) => {
    const operations = [];
    
    for (const userId of userIds) {
      for (const hostId of hostIds) {
        const isAuthorized = authorizations.some(auth => 
          auth.user_id === userId && auth.host_id === hostId
        );
        if (!isAuthorized) {
          operations.push({ userId, hostId });
        }
      }
    }

    // Set loading states
    const loadingKeys = operations.map(op => `${op.userId}-${op.hostId}`);
    setCellStates(prev => {
      const newMap = new Map(prev);
      loadingKeys.forEach(key => newMap.set(key, true));
      return newMap;
    });

    try {
      // Execute bulk operations
      await Promise.all(
        operations.map(op => onToggleAuthorization(op.userId, op.hostId, false))
      );
    } catch (error) {
      console.error('Bulk grant access failed:', error);
    } finally {
      // Clear loading states
      setCellStates(prev => {
        const newMap = new Map(prev);
        loadingKeys.forEach(key => newMap.delete(key));
        return newMap;
      });
    }
  };

  const handleBulkRevokeAccess = async (userIds: number[], hostIds: number[]) => {
    const operations = [];
    
    for (const userId of userIds) {
      for (const hostId of hostIds) {
        const isAuthorized = authorizations.some(auth => 
          auth.user_id === userId && auth.host_id === hostId
        );
        if (isAuthorized) {
          operations.push({ userId, hostId });
        }
      }
    }

    // Set loading states
    const loadingKeys = operations.map(op => `${op.userId}-${op.hostId}`);
    setCellStates(prev => {
      const newMap = new Map(prev);
      loadingKeys.forEach(key => newMap.set(key, true));
      return newMap;
    });

    try {
      // Execute bulk operations
      await Promise.all(
        operations.map(op => onToggleAuthorization(op.userId, op.hostId, true))
      );
    } catch (error) {
      console.error('Bulk revoke access failed:', error);
    } finally {
      // Clear loading states
      setCellStates(prev => {
        const newMap = new Map(prev);
        loadingKeys.forEach(key => newMap.delete(key));
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
    const isRowSelected = selectedUsers.has(cell.userId);
    const isColSelected = selectedHosts.has(cell.hostId);
    
    return cn(
      'w-8 h-8 flex items-center justify-center cursor-pointer transition-all duration-150 border border-gray-200 dark:border-gray-700',
      {
        // Authorization states
        'bg-green-50 dark:bg-green-900/20 hover:bg-green-100 dark:hover:bg-green-900/30': cell.isAuthorized && !cell.loading,
        'bg-gray-50 dark:bg-gray-800 hover:bg-gray-100 dark:hover:bg-gray-700': !cell.isAuthorized && !cell.loading,
        'bg-blue-50 dark:bg-blue-900/20': cell.loading,
        
        // Hover states
        'ring-2 ring-blue-500 ring-opacity-50': isHovered,
        
        // Selection states
        'bg-blue-100 dark:bg-blue-900/30': isRowSelected || isColSelected,
        
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
            <span>Loading authorization matrix...</span>
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
        
        {/* Search Input */}
        <div className="mt-4">
          <Input
            type="text"
            placeholder="Search users, hosts, or addresses..."
            value={searchTerm}
            onChange={(e) => setSearchTerm(e.target.value)}
            leftIcon={<Search size={16} />}
            className="max-w-md"
          />
        </div>
        
        {/* Bulk Actions */}
        {(selectedUsers.size > 0 || selectedHosts.size > 0) && (
          <div className="flex items-center space-x-2 mt-4 p-3 bg-blue-50 dark:bg-blue-900/20 rounded-lg">
            <span className="text-sm font-medium">
              Selected: {selectedUsers.size} users, {selectedHosts.size} hosts
            </span>
            <Button
              size="sm"
              onClick={() => handleBulkGrantAccess(Array.from(selectedUsers), Array.from(selectedHosts))}
              disabled={selectedUsers.size === 0 || selectedHosts.size === 0}
            >
              Grant Access
            </Button>
            <Button
              size="sm"
              variant="secondary"
              onClick={() => handleBulkRevokeAccess(Array.from(selectedUsers), Array.from(selectedHosts))}
              disabled={selectedUsers.size === 0 || selectedHosts.size === 0}
            >
              Revoke Access
            </Button>
            <Button
              size="sm"
              variant="ghost"
              onClick={() => {
                setSelectedUsers(new Set());
                setSelectedHosts(new Set());
              }}
            >
              Clear Selection
            </Button>
          </div>
        )}
      </CardHeader>
      
      <CardContent>
        {filteredUsers.length === 0 || filteredHosts.length === 0 ? (
          <div className="flex flex-col items-center justify-center py-12">
            <AlertCircle className="h-12 w-12 text-gray-400 mb-4" />
            <h3 className="text-lg font-medium text-gray-900 dark:text-white mb-2">
              No Data Available
            </h3>
            <p className="text-gray-500 dark:text-gray-400 text-center">
              {filteredUsers.length === 0 ? 'No users found.' : 'No hosts found.'}
              {showOnlyAuthorized && ' Try showing all users and hosts.'}
            </p>
          </div>
        ) : (
          <div className="overflow-auto max-h-[600px] border border-gray-200 dark:border-gray-700 rounded-lg">
            <div className="min-w-max">
              {/* Header with host names */}
              <div className="flex bg-gray-50 dark:bg-gray-800 sticky top-0 z-10">
                <div className="w-32 h-10 flex items-center px-3 border-r border-gray-200 dark:border-gray-700 font-medium text-sm">
                  Users / Hosts
                </div>
                {filteredHosts.map((host) => (
                  <div
                    key={host.id}
                    className={cn(
                      'w-8 h-10 flex items-center justify-center border-r border-gray-200 dark:border-gray-700 cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors',
                      selectedHosts.has(host.id) && 'bg-blue-100 dark:bg-blue-900/30'
                    )}
                    title={`${host.name} (${host.address})`}
                    onClick={() => {
                      setSelectedHosts(prev => {
                        const newSet = new Set(prev);
                        if (newSet.has(host.id)) {
                          newSet.delete(host.id);
                        } else {
                          newSet.add(host.id);
                        }
                        return newSet;
                      });
                    }}
                  >
                    <span className="text-xs font-medium transform -rotate-45 origin-center whitespace-nowrap">
                      {truncateText(host.name, 8)}
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
                      'w-32 h-8 flex items-center px-3 border-r border-b border-gray-200 dark:border-gray-700 text-sm cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors',
                      selectedUsers.has(user.id) && 'bg-blue-100 dark:bg-blue-900/30',
                      !user.enabled && 'text-gray-400 italic'
                    )}
                    title={`${user.username}${!user.enabled ? ' (disabled)' : ''}`}
                    onClick={() => {
                      setSelectedUsers(prev => {
                        const newSet = new Set(prev);
                        if (newSet.has(user.id)) {
                          newSet.delete(user.id);
                        } else {
                          newSet.add(user.id);
                        }
                        return newSet;
                      });
                    }}
                  >
                    <span className="truncate">
                      {truncateText(user.username)}
                      {!user.enabled && ' (disabled)'}
                    </span>
                  </div>

                  {/* Authorization cells */}
                  {filteredHosts.map((host) => {
                    const cell = matrixData[users.indexOf(user)]?.[hosts.indexOf(host)];
                    if (!cell) return null;

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
            <span>Authorized</span>
          </div>
          <div className="flex items-center space-x-2">
            <div className="w-4 h-4 bg-gray-50 dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded flex items-center justify-center">
              <X size={12} className="text-gray-400" />
            </div>
            <span>Not Authorized</span>
          </div>
          <div className="flex items-center space-x-2">
            <div className="w-4 h-4 bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded flex items-center justify-center">
              <Loader2 size={12} className="text-blue-500" />
            </div>
            <span>Updating</span>
          </div>
        </div>
      </CardContent>
    </Card>
  );
};

export default AuthorizationMatrix;