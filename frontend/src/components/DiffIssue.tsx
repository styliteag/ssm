import React, { useState } from 'react';
import { Check, Plus } from 'lucide-react';
import { DiffItemResponse } from '../services/api/diff';

interface DiffIssueProps {
  issue: DiffItemResponse;
  onAllowKey?: (issue: DiffItemResponse) => void;
  onAddUnknownKey?: (issue: DiffItemResponse) => void;
}

const getIssueIcon = (type: string) => {
  switch (type) {
    case 'pragma_missing':
      return '➕';
    case 'faulty_key':
      return '➖';
    case 'unknown_key':
      return '❓';
    case 'unauthorized_key':
      return '➖';
    case 'duplicate_key':
      return '➖';
    case 'incorrect_options':
      return '🔄';
    case 'key_missing':
      return '➕';
    default:
      return '🔄';
  }
};

const getIssueSeverity = (type: string) => {
  switch (type) {
    case 'pragma_missing':
      return 'addition';
    case 'faulty_key':
      return 'removal';
    case 'unknown_key':
      return 'warning';
    case 'unauthorized_key':
      return 'removal';
    case 'duplicate_key':
      return 'removal';
    case 'incorrect_options':
      return 'modification';
    case 'key_missing':
      return 'addition';
    default:
      return 'info';
  }
};

const getSeverityClasses = (severity: string) => {
  switch (severity) {
    case 'addition':
      return 'bg-green-50 dark:bg-green-900/20 border-green-200 dark:border-green-800 text-green-800 dark:text-green-200';
    case 'removal':
      return 'bg-red-50 dark:bg-red-900/20 border-red-200 dark:border-red-800 text-red-800 dark:text-red-200';
    case 'modification':
      return 'bg-blue-50 dark:bg-blue-900/20 border-blue-200 dark:border-blue-800 text-blue-800 dark:text-blue-200';
    case 'warning':
      return 'bg-yellow-50 dark:bg-yellow-900/20 border-yellow-200 dark:border-yellow-800 text-yellow-800 dark:text-yellow-200';
    case 'info':
      return 'bg-blue-50 dark:bg-blue-900/20 border-blue-200 dark:border-blue-800 text-blue-800 dark:text-blue-200';
    default:
      return 'bg-gray-50 dark:bg-gray-800 border-gray-200 dark:border-gray-700 text-gray-800 dark:text-gray-200';
  }
};

const getActionDescription = (type: string, description: string) => {
  switch (type) {
    case 'key_missing':
      // Transform "Missing key for user 'dev'" to "Will add key for user 'dev'"
      return description.replace(/^Missing key/, 'Will add key');
    case 'unauthorized_key':
      // Transform "Unauthorized key..." to "Will remove unauthorized key..."
      return description.replace(/^Unauthorized key/, 'Will remove key');
    case 'faulty_key':
      return description.replace(/^Faulty key/, 'Will remove faulty key');
    case 'duplicate_key':
      return description.replace(/^Duplicate key/, 'Will remove duplicate key');
    case 'pragma_missing':
      return description.replace(/^Missing/, 'Will add');
    case 'incorrect_options':
      return description.replace(/^Incorrect/, 'Will correct');
    default:
      return description;
  }
};

export const DiffIssue: React.FC<DiffIssueProps> = ({ issue, onAllowKey, onAddUnknownKey }) => {
  const [expanded, setExpanded] = useState(false);
  const severity = getIssueSeverity(issue.type);
  const severityClasses = getSeverityClasses(severity);
  const actionDescription = getActionDescription(issue.type, issue.description);

  return (
    <div className={`border rounded-lg p-3 ${severityClasses}`}>
      <div
        className="flex items-center justify-between cursor-pointer"
        onClick={() => setExpanded(!expanded)}
      >
        <div className="flex items-center space-x-2">
          <span className="text-lg">{getIssueIcon(issue.type)}</span>
          <span className="font-medium">{actionDescription}</span>
          <span className="text-xs px-2 py-1 bg-white dark:bg-gray-700 bg-opacity-50 dark:bg-opacity-50 rounded">
            {severity === 'addition' ? 'add' : severity === 'removal' ? 'remove' : severity === 'modification' ? 'modify' : issue.type.replace('_', ' ')}
          </span>
        </div>
        <div className="flex items-center space-x-2">
          {/* Allow button for unauthorized key issues */}
          {issue.type === 'unauthorized_key' && onAllowKey && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                onAllowKey(issue);
              }}
              className="inline-flex items-center space-x-1 px-2 py-1 bg-green-600 hover:bg-green-700 text-white text-xs font-medium rounded transition-colors"
            >
              <Check size={12} />
              <span>Allow</span>
            </button>
          )}
          {/* Add button for unknown key issues */}
          {issue.type === 'unknown_key' && onAddUnknownKey && (
            <button
              onClick={(e) => {
                e.stopPropagation();
                onAddUnknownKey(issue);
              }}
              className="inline-flex items-center space-x-1 px-2 py-1 bg-blue-600 hover:bg-blue-700 text-white text-xs font-medium rounded transition-colors"
            >
              <Plus size={12} />
              <span>Add</span>
            </button>
          )}
          <button className="text-sm font-medium text-current">
            {expanded ? '▲' : '▼'}
          </button>
        </div>
      </div>

      {expanded && issue.details && (
        <div className="mt-3 pt-3 border-t border-current border-opacity-20">
          <div className="space-y-2 text-sm text-current">
            {issue.details.username && (
              <div>
                <span className="font-medium">Username:</span> {issue.details.username}
              </div>
            )}
            
            {issue.details.key && (
              <div className="space-y-1">
                <span className="font-medium">Key Details:</span>
                <div className="bg-white dark:bg-gray-700 bg-opacity-30 dark:bg-opacity-30 rounded p-2 font-mono text-xs text-current">
                  <div><strong>Type:</strong> {issue.details.key.key_type}</div>
                  {issue.details.key.comment && <div><strong>Comment:</strong> {issue.details.key.comment}</div>}
                  {issue.details.key.options && <div><strong>Options:</strong> {issue.details.key.options}</div>}
                  <div><strong>Key (truncated):</strong> {issue.details.key.base64.substring(0, 32)}...</div>
                </div>
              </div>
            )}

            {issue.details.expected_options && (
              <div>
                <span className="font-medium">Expected Options:</span>
                <div className="bg-white dark:bg-gray-700 bg-opacity-30 dark:bg-opacity-30 rounded p-2 font-mono text-xs text-current">
                  {issue.details.expected_options}
                </div>
              </div>
            )}

            {issue.details.actual_options && (
              <div>
                <span className="font-medium">Actual Options:</span>
                <div className="bg-white dark:bg-gray-700 bg-opacity-30 dark:bg-opacity-30 rounded p-2 font-mono text-xs text-current">
                  {issue.details.actual_options}
                </div>
              </div>
            )}

            {issue.details.error && (
              <div>
                <span className="font-medium">Error:</span> {issue.details.error}
              </div>
            )}

            {issue.details.line && (
              <div>
                <span className="font-medium">Problem Line:</span>
                <div className="bg-white dark:bg-gray-700 bg-opacity-30 dark:bg-opacity-30 rounded p-2 font-mono text-xs break-all text-current">
                  {issue.details.line}
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
};

export default DiffIssue;