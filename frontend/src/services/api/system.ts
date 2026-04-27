import { api } from './base';

export interface ApiInfo {
  name: string;
  version: string;
  alembic_revision: string | null;
}

export const systemService = {
  /**
   * Get API information including backend version and applied alembic
   * revision. ``frontend version`` is injected at build time via Vite
   * (``__APP_VERSION__``) and read directly from the bundle.
   */
  getApiInfo: () => api.get<ApiInfo>('/info'),
};