import React, { useState } from 'react';
import { Eye, EyeOff, Copy, Download } from 'lucide-react';
import { cn } from '../../utils/cn';
import { DiffLine, FileDiff } from '../../types';
import { Button } from '../ui';

export interface DiffViewerProps {
  fileDiff: FileDiff;
  hostName: string;
  className?: string;
  showLineNumbers?: boolean;
  maxHeight?: string;
  collapsible?: boolean;
  showCopyButtons?: boolean;
  showDownloadButton?: boolean;
}

const DiffViewer: React.FC<DiffViewerProps> = ({
  fileDiff,
  hostName,
  className,
  showLineNumbers = true,
  maxHeight = '600px',
  collapsible = true,
  showCopyButtons = true,
  showDownloadButton = true,
}) => {
  const [viewMode, setViewMode] = useState<'split' | 'unified'>('split');
  const [showUnchanged, setShowUnchanged] = useState(false);
  const [collapsed, setCollapsed] = useState(false);

  const handleCopyToClipboard = async (content: string, _type: 'expected' | 'actual') => {
    try {
      await navigator.clipboard.writeText(content);
      // Copy succeeded
    } catch (err) {
      console.error('Failed to copy content:', err);
    }
  };

  const handleDownload = (content: string, filename: string) => {
    const blob = new Blob([content], { type: 'text/plain' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };

  const filteredLines = showUnchanged 
    ? fileDiff.lines 
    : fileDiff.lines.filter(line => line.type !== 'unchanged');

  const getLineTypeColor = (type: DiffLine['type']) => {
    switch (type) {
      case 'added':
        return 'bg-green-50 dark:bg-green-900/20 border-l-4 border-green-500';
      case 'removed':
        return 'bg-red-50 dark:bg-red-900/20 border-l-4 border-red-500';
      case 'modified':
        return 'bg-yellow-50 dark:bg-yellow-900/20 border-l-4 border-yellow-500';
      case 'unchanged':
        return 'bg-muted/50';
      default:
        return '';
    }
  };

  const getLineTypePrefix = (type: DiffLine['type']) => {
    switch (type) {
      case 'added':
        return '+';
      case 'removed':
        return '-';
      case 'modified':
        return '~';
      default:
        return ' ';
    }
  };

  const LineNumberColumn: React.FC<{ lineNumber?: number; type: DiffLine['type'] }> = ({ lineNumber, type }) => (
    <div className={cn(
      'w-12 flex-shrink-0 text-xs text-muted-foreground text-right pr-2 py-1 select-none',
      type === 'added' && 'bg-green-100 dark:bg-green-900/30',
      type === 'removed' && 'bg-red-100 dark:bg-red-900/30',
      type === 'modified' && 'bg-yellow-100 dark:bg-yellow-900/30'
    )}>
      {lineNumber || ''}
    </div>
  );

  const LineContent: React.FC<{ line: DiffLine }> = ({ line }) => (
    <div className="flex-1 font-mono text-sm text-foreground py-1 px-2 overflow-x-auto">
      <span className="text-muted-foreground mr-2 select-none">
        {getLineTypePrefix(line.type)}
      </span>
      <span className={cn(
        line.type === 'added' && 'text-green-800 dark:text-green-200',
        line.type === 'removed' && 'text-red-800 dark:text-red-200',
        line.type === 'modified' && 'text-yellow-800 dark:text-yellow-200'
      )}>
        {line.content}
      </span>
    </div>
  );

  if (collapsed && collapsible) {
    return (
      <div className={cn('border border-border rounded-lg', className)}>
        <div className="flex items-center justify-between p-4 bg-muted rounded-t-lg">
          <div className="flex items-center space-x-4">
            <h3 className="text-lg font-medium text-foreground">
              Diff for {hostName}
            </h3>
            <div className="flex items-center space-x-2 text-sm text-muted-foreground">
              <span className="text-green-600 dark:text-green-400">+{fileDiff.summary.added}</span>
              <span className="text-red-600 dark:text-red-400">-{fileDiff.summary.removed}</span>
              {fileDiff.summary.modified > 0 && (
                <span className="text-yellow-600 dark:text-yellow-400">~{fileDiff.summary.modified}</span>
              )}
            </div>
          </div>
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setCollapsed(false)}
            rightIcon={<Eye size={16} />}
          >
            Show Diff
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div className={cn('border border-border rounded-lg', className)}>
      {/* Header */}
      <div className="flex items-center justify-between p-4 bg-muted rounded-t-lg border-b border-border">
        <div className="flex items-center space-x-4">
          <h3 className="text-lg font-medium text-foreground">
            Diff for {hostName}
          </h3>
          <div className="flex items-center space-x-2 text-sm text-muted-foreground">
            <span className="text-green-600 dark:text-green-400">+{fileDiff.summary.added}</span>
            <span className="text-red-600 dark:text-red-400">-{fileDiff.summary.removed}</span>
            {fileDiff.summary.modified > 0 && (
              <span className="text-yellow-600 dark:text-yellow-400">~{fileDiff.summary.modified}</span>
            )}
          </div>
        </div>

        <div className="flex items-center space-x-2">
          {/* View mode toggle */}
          <div className="flex border border-input rounded-md">
            <Button
              variant={viewMode === 'split' ? 'primary' : 'ghost'}
              size="sm"
              onClick={() => setViewMode('split')}
              className="rounded-r-none"
            >
              Split
            </Button>
            <Button
              variant={viewMode === 'unified' ? 'primary' : 'ghost'}
              size="sm"
              onClick={() => setViewMode('unified')}
              className="rounded-l-none"
            >
              Unified
            </Button>
          </div>

          {/* Show unchanged toggle */}
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setShowUnchanged(!showUnchanged)}
            leftIcon={showUnchanged ? <EyeOff size={16} /> : <Eye size={16} />}
          >
            {showUnchanged ? 'Hide' : 'Show'} Unchanged
          </Button>

          {collapsible && (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setCollapsed(true)}
            >
              Collapse
            </Button>
          )}
        </div>
      </div>

      {/* Controls */}
      {(showCopyButtons || showDownloadButton) && (
        <div className="flex items-center justify-between p-2 bg-muted border-b border-border">
          <div className="text-sm text-muted-foreground">
            authorized_keys comparison
          </div>
          <div className="flex items-center space-x-2">
            {showCopyButtons && (
              <>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => handleCopyToClipboard(fileDiff.expected_content, 'expected')}
                  leftIcon={<Copy size={16} />}
                >
                  Copy Expected
                </Button>
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => handleCopyToClipboard(fileDiff.actual_content, 'actual')}
                  leftIcon={<Copy size={16} />}
                >
                  Copy Actual
                </Button>
              </>
            )}
            {showDownloadButton && (
              <Button
                variant="ghost"
                size="sm"
                onClick={() => handleDownload(
                  `Expected:\n${fileDiff.expected_content}\n\nActual:\n${fileDiff.actual_content}`,
                  `${hostName}-authorized_keys-diff.txt`
                )}
                leftIcon={<Download size={16} />}
              >
                Download
              </Button>
            )}
          </div>
        </div>
      )}

      {/* Diff content */}
      <div 
        className="overflow-auto bg-card"
        style={{ maxHeight }}
      >
        {viewMode === 'split' ? (
          <div className="flex">
            {/* Expected (left side) */}
            <div className="flex-1 border-r border-border">
              <div className="bg-muted px-4 py-2 text-sm font-medium text-foreground/80 border-b border-border">
                Expected
              </div>
              <div className="divide-y divide-border">
                {filteredLines.map((line, index) => {
                  if (line.type === 'added') return null;
                  return (
                    <div key={index} className={cn('flex', getLineTypeColor(line.type))}>
                      {showLineNumbers && (
                        <LineNumberColumn lineNumber={line.line_number_old} type={line.type} />
                      )}
                      <LineContent line={line} />
                    </div>
                  );
                })}
              </div>
            </div>

            {/* Actual (right side) */}
            <div className="flex-1">
              <div className="bg-muted px-4 py-2 text-sm font-medium text-foreground/80 border-b border-border">
                Actual
              </div>
              <div className="divide-y divide-border">
                {filteredLines.map((line, index) => {
                  if (line.type === 'removed') return null;
                  return (
                    <div key={index} className={cn('flex', getLineTypeColor(line.type))}>
                      {showLineNumbers && (
                        <LineNumberColumn lineNumber={line.line_number_new} type={line.type} />
                      )}
                      <LineContent line={line} />
                    </div>
                  );
                })}
              </div>
            </div>
          </div>
        ) : (
          /* Unified view */
          <div className="divide-y divide-border">
            {filteredLines.map((line, index) => (
              <div key={index} className={cn('flex', getLineTypeColor(line.type))}>
                {showLineNumbers && (
                  <>
                    <LineNumberColumn lineNumber={line.line_number_old} type={line.type} />
                    <LineNumberColumn lineNumber={line.line_number_new} type={line.type} />
                  </>
                )}
                <LineContent line={line} />
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Footer with summary */}
      <div className="p-3 bg-muted rounded-b-lg border-t border-border">
        <div className="text-sm text-muted-foreground">
          Total changes: {fileDiff.summary.added + fileDiff.summary.removed + fileDiff.summary.modified} lines
          {!showUnchanged && fileDiff.summary.unchanged > 0 && (
            <span> ({fileDiff.summary.unchanged} unchanged lines hidden)</span>
          )}
        </div>
      </div>
    </div>
  );
};

export default DiffViewer;