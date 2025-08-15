import React, { useState, useEffect } from 'react';
import { diffApi, DiffHost } from '../services/api/diff';

const DiffPage: React.FC = () => {
  const [hosts, setHosts] = useState<DiffHost[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [searchTerm, setSearchTerm] = useState('');
  const [sortBy, setSortBy] = useState<'name' | 'address'>('name');
  const [sortOrder, setSortOrder] = useState<'asc' | 'desc'>('asc');
  const [selectedHost, setSelectedHost] = useState<DiffHost | null>(null);
  const [hostDetails, setHostDetails] = useState<any>(null);
  const [detailsLoading, setDetailsLoading] = useState(false);

  useEffect(() => {
    const fetchHosts = async () => {
      try {
        setLoading(true);
        const hostData = await diffApi.getAllHosts();
        
        // Mark all hosts as loading diff data initially
        const hostsWithLoading = hostData.map(host => ({ ...host, loading: true }));
        setHosts(hostsWithLoading);
        setLoading(false);

        // Fetch diff data for each host in the background
        fetchDiffDataForHosts(hostData);
      } catch (err) {
        setError('Failed to load hosts');
        console.error('Error fetching hosts:', err);
        setLoading(false);
      }
    };

    const fetchDiffDataForHosts = async (hosts: DiffHost[]) => {
      // Process hosts in batches to avoid overwhelming the server
      const batchSize = 5;
      
      for (let i = 0; i < hosts.length; i += batchSize) {
        const batch = hosts.slice(i, i + batchSize);
        
        // Process batch in parallel
        const promises = batch.map(async (host) => {
          try {
            const diffData = await diffApi.getHostDiff(host.name);
            
            // Update the specific host with diff data
            setHosts(prevHosts => 
              prevHosts.map(h => 
                h.id === host.id 
                  ? { 
                      ...h, 
                      diff_summary: diffData.host ? `Found ${diffData.total_items} differences` : diffData.total_items.toString(),
                      is_empty: diffData.is_empty,
                      total_items: diffData.total_items,
                      loading: false 
                    }
                  : h
              )
            );
          } catch (err) {
            console.error(`Error fetching diff for ${host.name}:`, err);
            
            // Update host with error state
            setHosts(prevHosts => 
              prevHosts.map(h => 
                h.id === host.id 
                  ? { ...h, loading: false, error: 'Failed to load diff' }
                  : h
              )
            );
          }
        });

        await Promise.all(promises);
        
        // Small delay between batches to be nice to the server
        if (i + batchSize < hosts.length) {
          await new Promise(resolve => setTimeout(resolve, 100));
        }
      }
    };

    fetchHosts();
  }, []);

  const filteredAndSortedHosts = React.useMemo(() => {
    let filtered = hosts.filter(host =>
      host.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
      host.address.toLowerCase().includes(searchTerm.toLowerCase())
    );

    filtered.sort((a, b) => {
      const aValue = a[sortBy];
      const bValue = b[sortBy];
      const comparison = aValue.localeCompare(bValue);
      return sortOrder === 'asc' ? comparison : -comparison;
    });

    return filtered;
  }, [hosts, searchTerm, sortBy, sortOrder]);

  const handleSort = (column: 'name' | 'address') => {
    if (sortBy === column) {
      setSortOrder(sortOrder === 'asc' ? 'desc' : 'asc');
    } else {
      setSortBy(column);
      setSortOrder('asc');
    }
  };

  const getSortIcon = (column: 'name' | 'address') => {
    if (sortBy !== column) return '↕️';
    return sortOrder === 'asc' ? '↑' : '↓';
  };

  const handleHostClick = async (host: DiffHost) => {
    setSelectedHost(host);
    setDetailsLoading(true);
    
    try {
      // Fetch both diff details and basic host details
      const [diffData, hostData] = await Promise.all([
        diffApi.getHostDiff(host.name),
        diffApi.getHostDiffDetails(host.name)
      ]);
      
      setHostDetails({
        host: hostData,
        diff: diffData
      });
    } catch (err) {
      console.error('Error fetching host details:', err);
      setHostDetails({
        error: 'Failed to load host details'
      });
    } finally {
      setDetailsLoading(false);
    }
  };

  const closeModal = () => {
    setSelectedHost(null);
    setHostDetails(null);
  };

  if (loading) {
    return (
      <div className="flex justify-center items-center h-64">
        <div className="text-lg">Loading hosts...</div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex justify-center items-center h-64">
        <div className="text-red-600 text-lg">{error}</div>
      </div>
    );
  }

  return (
    <div className="p-6">
      <h1 className="text-2xl font-bold mb-6">Hosts Diff Overview</h1>
      
      <div className="mb-4">
        <input
          type="text"
          placeholder="Search hosts by name or address..."
          value={searchTerm}
          onChange={(e) => setSearchTerm(e.target.value)}
          className="w-full px-4 py-2 border border-gray-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-500"
        />
      </div>

      <div className="bg-white shadow-md rounded-lg overflow-hidden">
        <table className="min-w-full">
          <thead className="bg-gray-50">
            <tr>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                ID
              </th>
              <th 
                className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:bg-gray-100"
                onClick={() => handleSort('name')}
              >
                Name {getSortIcon('name')}
              </th>
              <th 
                className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider cursor-pointer hover:bg-gray-100"
                onClick={() => handleSort('address')}
              >
                Address {getSortIcon('address')}
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Status
              </th>
              <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                Differences
              </th>
            </tr>
          </thead>
          <tbody className="bg-white divide-y divide-gray-200">
            {filteredAndSortedHosts.map((host) => (
              <tr 
                key={host.id} 
                className="hover:bg-gray-50 cursor-pointer transition-colors"
                onClick={() => handleHostClick(host)}
              >
                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">
                  {host.id}
                </td>
                <td className="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900">
                  {host.name}
                </td>
                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                  {host.address}
                </td>
                <td className="px-6 py-4 whitespace-nowrap text-sm">
                  {host.loading ? (
                    <div className="flex items-center">
                      <div className="animate-spin rounded-full h-4 w-4 border-b-2 border-gray-900"></div>
                      <span className="ml-2 text-gray-500">Loading...</span>
                    </div>
                  ) : host.error ? (
                    <span className="text-red-600">Error</span>
                  ) : host.is_empty === false ? (
                    <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800">
                      Needs Sync
                    </span>
                  ) : host.is_empty === true ? (
                    <span className="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-green-100 text-green-800">
                      Synchronized
                    </span>
                  ) : (
                    <span className="text-gray-400">Unknown</span>
                  )}
                </td>
                <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-500">
                  {host.loading ? (
                    '-'
                  ) : host.error ? (
                    'Error'
                  ) : host.total_items !== undefined ? (
                    <span className={host.total_items > 0 ? 'text-red-600 font-medium' : 'text-gray-500'}>
                      {host.total_items} {host.total_items === 1 ? 'difference' : 'differences'}
                    </span>
                  ) : (
                    '-'
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        
        {filteredAndSortedHosts.length === 0 && (
          <div className="text-center py-8 text-gray-500">
            {searchTerm ? 'No hosts match your search criteria' : 'No hosts found'}
          </div>
        )}
      </div>
      
      <div className="mt-4 text-sm text-gray-600">
        Showing {filteredAndSortedHosts.length} of {hosts.length} hosts
      </div>

      {/* Host Details Modal */}
      {selectedHost && (
        <div 
          className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50"
          onClick={closeModal}
        >
          <div 
            className="bg-white rounded-lg shadow-xl max-w-2xl w-full m-4 max-h-[80vh] overflow-hidden"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex justify-between items-center p-6 border-b border-gray-200">
              <h2 className="text-xl font-semibold text-gray-900">
                Host Details: {selectedHost.name}
              </h2>
              <button
                onClick={closeModal}
                className="text-gray-400 hover:text-gray-600 transition-colors"
              >
                <svg className="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </div>
            
            <div className="p-6 overflow-y-auto">
              {detailsLoading ? (
                <div className="flex items-center justify-center py-8">
                  <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-gray-900"></div>
                  <span className="ml-3">Loading host details...</span>
                </div>
              ) : hostDetails?.error ? (
                <div className="text-red-600 py-4">
                  Error: {hostDetails.error}
                </div>
              ) : hostDetails ? (
                <div className="space-y-6">
                  {/* Basic Host Information */}
                  <div>
                    <h3 className="text-lg font-medium text-gray-900 mb-3">Host Information</h3>
                    <div className="bg-gray-50 rounded-lg p-4 space-y-2">
                      <div className="flex justify-between">
                        <span className="font-medium text-gray-700">ID:</span>
                        <span className="text-gray-900">{hostDetails.host?.id || selectedHost.id}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="font-medium text-gray-700">Name:</span>
                        <span className="text-gray-900">{hostDetails.host?.name || selectedHost.name}</span>
                      </div>
                      <div className="flex justify-between">
                        <span className="font-medium text-gray-700">Address:</span>
                        <span className="text-gray-900">{hostDetails.host?.address || selectedHost.address}</span>
                      </div>
                    </div>
                  </div>

                  {/* Diff Information */}
                  <div>
                    <h3 className="text-lg font-medium text-gray-900 mb-3">Diff Status</h3>
                    <div className="bg-gray-50 rounded-lg p-4 space-y-2">
                      <div className="flex justify-between">
                        <span className="font-medium text-gray-700">Status:</span>
                        <span className={`inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${
                          hostDetails.diff?.is_empty 
                            ? 'bg-green-100 text-green-800' 
                            : 'bg-red-100 text-red-800'
                        }`}>
                          {hostDetails.diff?.is_empty ? 'Synchronized' : 'Needs Sync'}
                        </span>
                      </div>
                      <div className="flex justify-between">
                        <span className="font-medium text-gray-700">Differences:</span>
                        <span className={`text-gray-900 ${hostDetails.diff?.total_items > 0 ? 'font-medium text-red-600' : ''}`}>
                          {hostDetails.diff?.total_items || 0}
                        </span>
                      </div>
                      {hostDetails.diff?.diff_summary && (
                        <div className="flex justify-between">
                          <span className="font-medium text-gray-700">Summary:</span>
                          <span className="text-gray-900">{hostDetails.diff.diff_summary}</span>
                        </div>
                      )}
                    </div>
                  </div>

                  {/* Additional Actions */}
                  <div className="pt-4 border-t border-gray-200">
                    <div className="flex space-x-3">
                      <button className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 transition-colors">
                        View Full Diff
                      </button>
                      <button className="px-4 py-2 bg-green-600 text-white rounded-md hover:bg-green-700 transition-colors">
                        Sync Keys
                      </button>
                    </div>
                  </div>
                </div>
              ) : null}
            </div>
          </div>
        </div>
      )}
    </div>
  );
};

export default DiffPage;