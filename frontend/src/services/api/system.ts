import { api } from './base';

export interface ApiInfo {
  name: string;
  version: string;
  description: string;
}

export const systemService = {
  /**
   * Get API information including version
   */
  getApiInfo: () => api.get<ApiInfo>('/'),
};