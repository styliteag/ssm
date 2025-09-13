import React, { useState, useMemo } from 'react';
import { ChevronUp, ChevronDown, Search, ChevronLeft, ChevronRight } from 'lucide-react';
import { cn } from '../../utils/cn';
import Button from './Button';
import Input from './Input';

export interface Column<T> {
  key: keyof T | 'actions';
  header: string;
  sortable?: boolean;
  searchable?: boolean;
  width?: string;
  render?: (value: unknown, item: T, index: number) => React.ReactNode;
  className?: string;
  headerClassName?: string;
}

export interface SortConfig<T> {
  key: keyof T;
  direction: 'asc' | 'desc';
}

export interface DataTableProps<T> {
  data: T[];
  columns: Column<T>[];
  loading?: boolean;
  searchable?: boolean;
  sortable?: boolean;
  paginated?: boolean;
  pageSize?: number;
  initialSort?: SortConfig<T>;
  initialSearch?: string;
  onRowClick?: (item: T, index: number) => void;
  emptyMessage?: string;
  className?: string;
  searchPlaceholder?: string;
  showSearchIcon?: boolean;
  stickyHeader?: boolean;
  // Selection functionality
  selectable?: boolean;
  selectedItems?: T[];
  onSelectionChange?: (selectedItems: T[]) => void;
  getItemId?: (item: T) => string | number;
  // Custom row styling
  getRowClassName?: (item: T, index: number) => string;
}

function DataTable<T extends Record<string, unknown>>({
  data,
  columns,
  loading = false,
  searchable = true,
  sortable = true,
  paginated = true,
  pageSize = 10,
  initialSort,
  initialSearch = '',
  onRowClick,
  emptyMessage = 'No data available',
  className,
  searchPlaceholder = 'Search...',
  showSearchIcon = true,
  stickyHeader = false,
  // Selection props
  selectable = false,
  selectedItems = [],
  onSelectionChange,
  getItemId = (item: T) => item.id as string | number,
  // Custom row styling
  getRowClassName,
}: DataTableProps<T>) {
  const [search, setSearch] = useState(initialSearch);
  const [sortConfig, setSortConfig] = useState<SortConfig<T> | null>(initialSort || null);
  const [currentPage, setCurrentPage] = useState(1);
  const [itemsPerPage, setItemsPerPage] = useState(pageSize);


  // Filter data based on search
  const filteredData = useMemo(() => {
    if (!searchable || !search.trim()) return data;

    const searchLower = search.toLowerCase();

    return data.filter(item => {
      // If item has a combined_search field, use it for comprehensive search
      if (item.combined_search && typeof item.combined_search === 'string') {
        return item.combined_search.includes(searchLower);
      }

      // Otherwise, search through individual searchable columns
      const searchableColumns = columns.filter(col => col.searchable !== false);
      return searchableColumns.some(column => {
        if (column.key === 'actions') return false;
        const value = item[column.key];
        return value && value.toString().toLowerCase().includes(searchLower);
      });
    });
  }, [data, search, searchable, columns]);

  // Sort data
  const sortedData = useMemo(() => {
    if (!sortable || !sortConfig) return filteredData;

    return [...filteredData].sort((a, b) => {
      const aValue = a[sortConfig.key];
      const bValue = b[sortConfig.key];

      // Handle null/undefined values
      if (aValue == null && bValue == null) return 0;
      if (aValue == null) return 1;
      if (bValue == null) return -1;

      // Type-safe comparison
      let comparison = 0;
      if (typeof aValue === 'string' && typeof bValue === 'string') {
        comparison = aValue.localeCompare(bValue);
      } else if (typeof aValue === 'number' && typeof bValue === 'number') {
        comparison = aValue - bValue;
      } else if ((aValue as unknown) instanceof Date && (bValue as unknown) instanceof Date) {
        comparison = ((aValue as unknown) as Date).getTime() - ((bValue as unknown) as Date).getTime();
      } else {
        comparison = String(aValue).localeCompare(String(bValue));
      }

      return sortConfig.direction === 'desc' ? -comparison : comparison;
    });
  }, [filteredData, sortConfig, sortable]);

  // Paginate data
  const paginatedData = useMemo(() => {
    if (!paginated) return sortedData;

    const startIndex = (currentPage - 1) * itemsPerPage;
    return sortedData.slice(startIndex, startIndex + itemsPerPage);
  }, [sortedData, currentPage, itemsPerPage, paginated]);

  // Calculate pagination info
  const totalPages = Math.ceil(sortedData.length / itemsPerPage);
  const startItem = (currentPage - 1) * itemsPerPage + 1;
  const endItem = Math.min(startItem + itemsPerPage - 1, sortedData.length);

  // Handle sorting
  const handleSort = (key: keyof T) => {
    if (!sortable) return;

    const column = columns.find(col => col.key === key);
    if (!column || column.sortable === false) return;

    setSortConfig(current => {
      if (current?.key === key) {
        if (current.direction === 'asc') {
          return { key, direction: 'desc' };
        } else {
          return null; // Clear sort
        }
      }
      return { key, direction: 'asc' };
    });
  };

  // Reset to first page when search changes
  React.useEffect(() => {
    setCurrentPage(1);
  }, [search]);

  // Selection helpers
  const isItemSelected = (item: T): boolean => {
    if (!selectable) return false;
    return selectedItems.some(selected => getItemId(selected) === getItemId(item));
  };

  const handleSelectItem = (item: T, checked: boolean) => {
    if (!selectable || !onSelectionChange) return;
    
    if (checked) {
      onSelectionChange([...selectedItems, item]);
    } else {
      onSelectionChange(selectedItems.filter(selected => getItemId(selected) !== getItemId(item)));
    }
  };

  const handleSelectAll = (checked: boolean) => {
    if (!selectable || !onSelectionChange) return;
    
    if (checked) {
      // Select all items in current filtered data
      const newSelection = [...selectedItems];
      filteredData.forEach(item => {
        if (!selectedItems.some(selected => getItemId(selected) === getItemId(item))) {
          newSelection.push(item);
        }
      });
      onSelectionChange(newSelection);
    } else {
      // Deselect all items in current filtered data
      const filteredIds = filteredData.map(getItemId);
      onSelectionChange(selectedItems.filter(selected => !filteredIds.includes(getItemId(selected))));
    }
  };

  // Check if all visible items are selected
  const allVisibleSelected = selectable && filteredData.length > 0 && 
    filteredData.every(item => selectedItems.some(selected => getItemId(selected) === getItemId(item)));
  
  // Check if some visible items are selected (for indeterminate state)
  const someVisibleSelected = selectable && filteredData.length > 0 && 
    filteredData.some(item => selectedItems.some(selected => getItemId(selected) === getItemId(item))) &&
    !allVisibleSelected;

  const SortIcon: React.FC<{ column: Column<T> }> = ({ column }) => {
    if (!sortable || column.sortable === false || column.key === 'actions') {
      return null;
    }

    const isActive = sortConfig?.key === column.key;
    const direction = sortConfig?.direction;

    return (
      <span className="ml-1 inline-flex flex-col">
        <ChevronUp 
          size={12} 
          className={cn(
            'transition-colors',
            isActive && direction === 'asc' 
              ? 'text-blue-600 dark:text-blue-400' 
              : 'text-gray-400 dark:text-gray-600'
          )}
        />
        <ChevronDown 
          size={12} 
          className={cn(
            'transition-colors -mt-1',
            isActive && direction === 'desc' 
              ? 'text-blue-600 dark:text-blue-400' 
              : 'text-gray-400 dark:text-gray-600'
          )}
        />
      </span>
    );
  };

  const LoadingRow = () => (
    <tr>
      <td colSpan={columns.length + (selectable ? 1 : 0)} className="px-6 py-8 text-center">
        <div className="flex items-center justify-center space-x-2">
          <div className="animate-spin rounded-full h-6 w-6 border-b-2 border-blue-600"></div>
          <span className="text-gray-500 dark:text-gray-400">Loading...</span>
        </div>
      </td>
    </tr>
  );

  const EmptyRow = () => (
    <tr>
      <td colSpan={columns.length + (selectable ? 1 : 0)} className="px-6 py-8 text-center text-gray-500 dark:text-gray-400">
        {emptyMessage}
      </td>
    </tr>
  );

  return (
    <div className={cn('space-y-4', className)}>
      {/* Search */}
      {searchable && (
        <div className="flex items-center justify-between">
          <div className="flex-1 max-w-sm">
            <Input
              type="text"
              placeholder={searchPlaceholder}
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              leftIcon={showSearchIcon ? <Search size={16} /> : undefined}
              className="w-full"
            />
          </div>
          
          {paginated && (
            <div className="flex items-center space-x-2">
              <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
                Show:
              </label>
              <select
                value={itemsPerPage}
                onChange={(e) => {
                  setItemsPerPage(Number(e.target.value));
                  setCurrentPage(1);
                }}
                className="h-8 px-2 py-1 text-sm border border-gray-300 rounded-md bg-white dark:bg-gray-800 dark:border-gray-600 dark:text-gray-100 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent"
              >
                <option value={5}>5</option>
                <option value={10}>10</option>
                <option value={25}>25</option>
                <option value={50}>50</option>
                <option value={100}>100</option>
              </select>
              <span className="text-sm text-gray-700 dark:text-gray-300">entries</span>
            </div>
          )}
        </div>
      )}

      {/* Table */}
      <div className="overflow-hidden rounded-lg border border-gray-200 dark:border-gray-700">
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
            <thead className={cn(
              'bg-gray-50 dark:bg-gray-800',
              stickyHeader && 'sticky top-0 z-10'
            )}>
              <tr>
                {selectable && (
                  <th className="px-6 py-3 text-left w-12">
                    <input
                      type="checkbox"
                      checked={allVisibleSelected}
                      ref={(input) => {
                        if (input) {
                          input.indeterminate = someVisibleSelected;
                        }
                      }}
                      onChange={(e) => handleSelectAll(e.target.checked)}
                      className="h-4 w-4 text-blue-600 focus:ring-blue-500 border-gray-300 rounded"
                    />
                  </th>
                )}
                {columns.map((column) => (
                  <th
                    key={String(column.key)}
                    className={cn(
                      'px-6 py-3 text-left text-xs font-medium text-gray-500 dark:text-gray-300 uppercase tracking-wider',
                      sortable && column.sortable !== false && column.key !== 'actions' && 'cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors',
                      column.headerClassName
                    )}
                    style={{ width: column.width }}
                    onClick={() => column.key !== 'actions' && handleSort(column.key as keyof T)}
                  >
                    <div className="flex items-center justify-between">
                      <span>{column.header}</span>
                      <SortIcon column={column} />
                    </div>
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="bg-white dark:bg-gray-900 divide-y divide-gray-200 dark:divide-gray-700">
              {loading ? (
                <LoadingRow />
              ) : paginatedData.length === 0 ? (
                <EmptyRow />
              ) : (
                paginatedData.map((item, index) => (
                  <tr
                    key={(item.id as React.Key) || index}
                    className={cn(
                      'transition-colors',
                      onRowClick && 'cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-800',
                      selectable && isItemSelected(item) && 'bg-blue-50 dark:bg-blue-900/20',
                      getRowClassName?.(item, index)
                    )}
                    onClick={(e) => {
                      // Don't trigger row click if clicking on checkbox
                      if (selectable && (e.target as HTMLInputElement).type === 'checkbox') return;
                      onRowClick?.(item, index);
                    }}
                  >
                    {selectable && (
                      <td className="px-6 py-4 whitespace-nowrap w-12">
                        <input
                          type="checkbox"
                          checked={isItemSelected(item)}
                          onChange={(e) => {
                            e.stopPropagation();
                            handleSelectItem(item, e.target.checked);
                          }}
                          className="h-4 w-4 text-blue-600 focus:ring-blue-500 border-gray-300 rounded"
                        />
                      </td>
                    )}
                    {columns.map((column) => (
                      <td
                        key={String(column.key)}
                        className={cn(
                          'px-6 py-4 whitespace-nowrap text-sm text-gray-900 dark:text-gray-100',
                          column.className
                        )}
                      >
                        {column.render ? (
                          column.render(
                            column.key === 'actions' ? item : item[column.key],
                            item,
                            (currentPage - 1) * itemsPerPage + index
                          )
                        ) : column.key === 'actions' ? (
                          ''
                        ) : (
                          String(item[column.key] || '')
                        )}
                      </td>
                    ))}
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Pagination */}
      {paginated && totalPages > 1 && (
        <div className="flex items-center justify-between">
          <div className="text-sm text-gray-700 dark:text-gray-300">
            Showing {startItem} to {endItem} of {sortedData.length} entries
            {search && ` (filtered from ${data.length} total entries)`}
          </div>
          
          <div className="flex items-center space-x-2">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setCurrentPage(p => Math.max(1, p - 1))}
              disabled={currentPage === 1}
              leftIcon={<ChevronLeft size={16} />}
            >
              Previous
            </Button>
            
            <div className="flex items-center space-x-1">
              {[...Array(Math.min(totalPages, 7))].map((_, i) => {
                let pageNum;
                if (totalPages <= 7) {
                  pageNum = i + 1;
                } else if (currentPage <= 4) {
                  pageNum = i + 1;
                } else if (currentPage >= totalPages - 3) {
                  pageNum = totalPages - 6 + i;
                } else {
                  pageNum = currentPage - 3 + i;
                }

                if (pageNum < 1 || pageNum > totalPages) return null;

                return (
                  <Button
                    key={pageNum}
                    variant={currentPage === pageNum ? 'primary' : 'ghost'}
                    size="sm"
                    onClick={() => setCurrentPage(pageNum)}
                    className="w-8 h-8 p-0"
                  >
                    {pageNum}
                  </Button>
                );
              })}
            </div>
            
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setCurrentPage(p => Math.min(totalPages, p + 1))}
              disabled={currentPage === totalPages}
              rightIcon={<ChevronRight size={16} />}
            >
              Next
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

export default DataTable;