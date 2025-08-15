import React, { useState } from 'react';
import { DiffItemResponse } from '../services/api/diff';

interface DiffIssueProps {
  issue: DiffItemResponse;
}

const getIssueIcon = (type: string) => {
  switch (type) {
    case 'pragma_missing':
      return '⚠️';
    case 'faulty_key':
      return '❌';
    case 'unknown_key':
      return '❓';
    case 'unauthorized_key':
      return '🔒';
    case 'duplicate_key':
      return '📋';
    case 'incorrect_options':
      return '⚙️';
    case 'key_missing':
      return '➖';
    default:
      return '❓';
  }
};

const getIssueSeverity = (type: string) => {
  switch (type) {
    case 'pragma_missing':
      return 'warning';
    case 'faulty_key':
      return 'error';
    case 'unknown_key':
      return 'warning';
    case 'unauthorized_key':
      return 'error';
    case 'duplicate_key':
      return 'warning';
    case 'incorrect_options':
      return 'warning';
    case 'key_missing':
      return 'error';
    default:
      return 'info';
  }
};

const getSeverityClasses = (severity: string) => {
  switch (severity) {
    case 'error':
      return 'bg-red-50 border-red-200 text-red-800';
    case 'warning':
      return 'bg-yellow-50 border-yellow-200 text-yellow-800';
    case 'info':
      return 'bg-blue-50 border-blue-200 text-blue-800';
    default:
      return 'bg-gray-50 border-gray-200 text-gray-800';
  }
};

export const DiffIssue: React.FC<DiffIssueProps> = ({ issue }) => {
  const [expanded, setExpanded] = useState(false);
  const severity = getIssueSeverity(issue.type);
  const severityClasses = getSeverityClasses(severity);

  return (
    <div className={`border rounded-lg p-3 ${severityClasses}`}>
      <div 
        className="flex items-center justify-between cursor-pointer"
        onClick={() => setExpanded(!expanded)}
      >
        <div className="flex items-center space-x-2">
          <span className="text-lg">{getIssueIcon(issue.type)}</span>
          <span className="font-medium">{issue.description}</span>
          <span className="text-xs px-2 py-1 bg-white bg-opacity-50 rounded">
            {issue.type.replace('_', ' ')}
          </span>
        </div>
        <button className="text-sm font-medium hover:underline">
          {expanded ? 'Less' : 'More'} {expanded ? '▲' : '▼'}
        </button>
      </div>

      {expanded && issue.details && (
        <div className="mt-3 pt-3 border-t border-current border-opacity-20">
          <div className="space-y-2 text-sm">
            {issue.details.username && (
              <div>
                <span className="font-medium">Username:</span> {issue.details.username}
              </div>
            )}
            
            {issue.details.key && (
              <div className="space-y-1">
                <span className="font-medium">Key Details:</span>
                <div className="bg-white bg-opacity-30 rounded p-2 font-mono text-xs">
                  <div><strong>Type:</strong> {issue.details.key.base64.startsWith('AAAAB3NzaC1yc2') ? 'RSA' : 
                                                issue.details.key.base64.startsWith('AAAAC3NzaC1lZDI1NTE5') ? 'Ed25519' : 
                                                issue.details.key.base64.startsWith('AAAAE2VjZHNhLXNoYTItbmlzdHA') ? 'ECDSA' : 'Unknown'}</div>
                  {issue.details.key.comment && <div><strong>Comment:</strong> {issue.details.key.comment}</div>}
                  {issue.details.key.options && <div><strong>Options:</strong> {issue.details.key.options}</div>}
                  <div><strong>Key (truncated):</strong> {issue.details.key.base64.substring(0, 32)}...</div>
                </div>
              </div>
            )}

            {issue.details.expected_options && (
              <div>
                <span className="font-medium">Expected Options:</span>
                <div className="bg-white bg-opacity-30 rounded p-2 font-mono text-xs">
                  {issue.details.expected_options}
                </div>
              </div>
            )}

            {issue.details.actual_options && (
              <div>
                <span className="font-medium">Actual Options:</span>
                <div className="bg-white bg-opacity-30 rounded p-2 font-mono text-xs">
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
                <div className="bg-white bg-opacity-30 rounded p-2 font-mono text-xs break-all">
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