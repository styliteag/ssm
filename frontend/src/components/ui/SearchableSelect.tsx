import React, { useState, useRef, useEffect, useCallback } from 'react';
import { cn } from '../../utils/cn';

export interface SelectOption {
  value: string | number;
  label: string;
  disabled?: boolean;
}

export interface SearchableSelectProps {
  id?: string;
  name?: string;
  value?: string | number;
  options: SelectOption[];
  placeholder?: string;
  disabled?: boolean;
  className?: string;
  onValueChange?: (value: string | number) => void;
  onBlur?: () => void;
  searchPlaceholder?: string;
  emptyMessage?: string;
  forcePosition?: 'top' | 'bottom'; // Override automatic positioning
}

const SearchableSelect: React.FC<SearchableSelectProps> = ({
  id,
  name,
  value,
  options,
  placeholder = 'Select an option...',
  disabled = false,
  className,
  onValueChange,
  onBlur,
  searchPlaceholder = 'Search options...',
  emptyMessage = 'No options found',
  forcePosition,
}) => {
  const [isOpen, setIsOpen] = useState(false);
  const [searchTerm, setSearchTerm] = useState('');
  const [focusedIndex, setFocusedIndex] = useState(-1);
  const [dropdownPosition, setDropdownPosition] = useState<'bottom' | 'top'>('bottom');
  
  const containerRef = useRef<HTMLDivElement>(null);
  const searchInputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLUListElement>(null);
  const dropdownRef = useRef<HTMLDivElement>(null);

  // Filter options based on search term
  const filteredOptions = options.filter(option =>
    option.label.toLowerCase().includes(searchTerm.toLowerCase())
  );

  // Get selected option display
  const selectedOption = options.find(option => option.value === value);
  const displayValue = selectedOption ? selectedOption.label : '';

  // Handle clicking outside to close dropdown
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(event.target as Node)) {
        setIsOpen(false);
        setSearchTerm('');
        setFocusedIndex(-1);
        onBlur?.();
      }
    };

    if (isOpen) {
      document.addEventListener('mousedown', handleClickOutside);
      return () => document.removeEventListener('mousedown', handleClickOutside);
    }
  }, [isOpen, onBlur]);

  // Calculate dropdown position based on available space
  const calculateDropdownPosition = useCallback(() => {
    if (!containerRef.current) return;

    const containerRect = containerRef.current.getBoundingClientRect();
    const viewportHeight = window.innerHeight;
    const dropdownHeight = Math.min(250, filteredOptions.length * 36 + 60); // More conservative height estimate
    
    const spaceBelow = viewportHeight - containerRect.bottom - 40; // More conservative padding
    const spaceAbove = containerRect.top - 40; // More conservative padding
    
    // Check if we're inside a modal
    const isInModal = containerRef.current.closest('[role="dialog"], [aria-modal="true"], .modal, [data-modal="true"]') !== null;
    
    // More aggressive upward positioning logic
    // If there's insufficient space below OR if we're in the bottom half of the viewport OR in a modal
    const isInBottomHalf = containerRect.top > viewportHeight / 2;
    const hasInsufficientSpaceBelow = spaceBelow < dropdownHeight;
    const hasEnoughSpaceAbove = spaceAbove > 120; // Reduced minimum space above needed
    
    // Override with forcePosition if provided
    if (forcePosition) {
      setDropdownPosition(forcePosition);
    } else if (isInModal && spaceAbove > 100) {
      setDropdownPosition('top');
    } else if ((hasInsufficientSpaceBelow || isInBottomHalf) && hasEnoughSpaceAbove) {
      setDropdownPosition('top');
    } else {
      setDropdownPosition('bottom');
    }
  }, [filteredOptions.length, forcePosition]);

  // Focus search input when dropdown opens and calculate position
  useEffect(() => {
    if (isOpen) {
      calculateDropdownPosition();
      if (searchInputRef.current) {
        searchInputRef.current.focus();
      }
    }
  }, [isOpen, calculateDropdownPosition]);

  // Recalculate position when search term changes (affects dropdown content size)
  useEffect(() => {
    if (isOpen) {
      calculateDropdownPosition();
    }
  }, [searchTerm, isOpen, calculateDropdownPosition]);

  // Handle keyboard navigation
  const handleKeyDown = (event: React.KeyboardEvent) => {
    if (disabled) return;

    switch (event.key) {
      case 'ArrowDown':
        event.preventDefault();
        if (!isOpen) {
          setIsOpen(true);
        } else {
          setFocusedIndex(prev => 
            prev < filteredOptions.length - 1 ? prev + 1 : 0
          );
        }
        break;
      
      case 'ArrowUp':
        event.preventDefault();
        if (isOpen) {
          setFocusedIndex(prev => 
            prev > 0 ? prev - 1 : filteredOptions.length - 1
          );
        }
        break;
      
      case 'Enter':
        event.preventDefault();
        if (isOpen && focusedIndex >= 0 && filteredOptions[focusedIndex]) {
          const selectedOption = filteredOptions[focusedIndex];
          if (!selectedOption.disabled) {
            onValueChange?.(selectedOption.value);
            setIsOpen(false);
            setSearchTerm('');
            setFocusedIndex(-1);
          }
        } else if (!isOpen) {
          setIsOpen(true);
        }
        break;
      
      case 'Escape':
        event.preventDefault();
        setIsOpen(false);
        setSearchTerm('');
        setFocusedIndex(-1);
        break;
    }
  };

  // Handle option selection
  const handleOptionSelect = (option: SelectOption) => {
    if (option.disabled) return;
    
    onValueChange?.(option.value);
    setIsOpen(false);
    setSearchTerm('');
    setFocusedIndex(-1);
  };

  // Handle trigger click
  const handleTriggerClick = () => {
    if (disabled) return;
    setIsOpen(!isOpen);
  };

  // Scroll focused option into view
  useEffect(() => {
    if (focusedIndex >= 0 && listRef.current) {
      const focusedElement = listRef.current.children[focusedIndex] as HTMLElement;
      if (focusedElement) {
        focusedElement.scrollIntoView({
          block: 'nearest',
        });
      }
    }
  }, [focusedIndex]);

  return (
    <div ref={containerRef} className={cn('relative', className)}>
      {/* Trigger Button */}
      <button
        type="button"
        id={id}
        name={name}
        className={cn(
          'flex h-10 w-full items-center justify-between rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-left text-gray-900',
          'focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent',
          'disabled:cursor-not-allowed disabled:opacity-50',
          'dark:border-gray-600 dark:bg-gray-800 dark:text-gray-100',
          'hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors',
          isOpen && 'ring-2 ring-blue-500 border-transparent'
        )}
        onClick={handleTriggerClick}
        onKeyDown={handleKeyDown}
        disabled={disabled}
        aria-expanded={isOpen}
        aria-haspopup="listbox"
        aria-label={placeholder}
      >
        <span className={cn(
          displayValue ? 'text-gray-900 dark:text-gray-100' : 'text-gray-400 dark:text-gray-500'
        )}>
          {displayValue || placeholder}
        </span>
        <svg
          className={cn(
            'h-4 w-4 text-gray-400 dark:text-gray-500 transition-transform duration-200',
            isOpen && (dropdownPosition === 'top' ? '-rotate-180' : 'rotate-180')
          )}
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      {/* Dropdown */}
      {isOpen && (
        <div 
          ref={dropdownRef}
          className={cn(
            "absolute z-50 w-full bg-white border border-gray-300 rounded-md shadow-lg dark:bg-gray-800 dark:border-gray-600 dark:shadow-gray-900/25",
            dropdownPosition === 'bottom' ? 'mt-1' : 'mb-1 bottom-full',
            // Responsive width constraints and overflow handling
            "min-w-full max-w-sm",
            // Ensure dropdown doesn't overflow modal bounds
            "left-0 right-0"
          )}
        >
          {/* Search Input */}
          <div className="p-2">
            <input
              ref={searchInputRef}
              type="text"
              className={cn(
                'w-full px-3 py-2 text-sm border border-gray-300 rounded-md bg-white text-gray-900 placeholder:text-gray-400',
                'focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent',
                'dark:border-gray-600 dark:bg-gray-700 dark:text-gray-100 dark:placeholder:text-gray-500'
              )}
              placeholder={searchPlaceholder}
              value={searchTerm}
              onChange={(e) => {
                setSearchTerm(e.target.value);
                setFocusedIndex(-1);
              }}
              onKeyDown={handleKeyDown}
            />
          </div>

          {/* Options List */}
          <ul
            ref={listRef}
            className={cn(
              "overflow-auto py-1",
              // Dynamic max height based on available space
              dropdownPosition === 'bottom' ? "max-h-48" : "max-h-40"
            )}
            role="listbox"
          >
            {filteredOptions.length > 0 ? (
              filteredOptions.map((option, index) => (
                <li
                  key={option.value}
                  className={cn(
                    'relative cursor-pointer select-none py-2 px-3 text-sm text-gray-900 dark:text-gray-100',
                    'hover:bg-blue-50 hover:text-blue-900 dark:hover:bg-gray-700 dark:hover:text-gray-100',
                    focusedIndex === index && 'bg-blue-50 text-blue-900 dark:bg-gray-700 dark:text-gray-100',
                    option.disabled && 'cursor-not-allowed opacity-50',
                    value === option.value && 'bg-blue-100 text-blue-900 dark:bg-blue-900 dark:text-blue-100 font-medium'
                  )}
                  onClick={() => handleOptionSelect(option)}
                  role="option"
                  aria-selected={value === option.value}
                >
                  <span className="block truncate">{option.label}</span>
                  {value === option.value && (
                    <span className="absolute inset-y-0 right-0 flex items-center pr-3 text-blue-600 dark:text-blue-300">
                      <svg className="h-4 w-4" fill="currentColor" viewBox="0 0 20 20">
                        <path fillRule="evenodd" d="M16.707 5.293a1 1 0 010 1.414l-8 8a1 1 0 01-1.414 0l-4-4a1 1 0 011.414-1.414L8 12.586l7.293-7.293a1 1 0 011.414 0z" clipRule="evenodd" />
                      </svg>
                    </span>
                  )}
                </li>
              ))
            ) : (
              <li className="py-2 px-3 text-sm text-gray-500 dark:text-gray-400 italic">
                {emptyMessage}
              </li>
            )}
          </ul>
        </div>
      )}
    </div>
  );
};

export default SearchableSelect;