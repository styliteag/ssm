import { ApiResponse } from './types';
import { http } from './base';
import { ActivityLogEntry, Meta } from './types';

export interface ActivityLogQuery {
  page?: number;
  page_size?: number;
  activity_type?: 'key' | 'host' | 'user' | 'auth';
}

export interface ActivityLogPage {
  items: ActivityLogEntry[];
  meta: Meta;
}

const qs = (q: ActivityLogQuery): string => {
  const params = new URLSearchParams();
  if (q.page !== undefined) params.set('page', String(q.page));
  if (q.page_size !== undefined) params.set('page_size', String(q.page_size));
  if (q.activity_type !== undefined) params.set('activity_type', q.activity_type);
  const s = params.toString();
  return s ? `?${s}` : '';
};

export const activityLogApi = {
  list: async (query: ActivityLogQuery = {}): Promise<ActivityLogPage> => {
    const resp: ApiResponse<ActivityLogEntry[]> = await http.get<ActivityLogEntry[]>(
      `/activity-log${qs(query)}`,
    );
    if (!resp.success) {
      throw new Error(resp.error?.message ?? 'failed to load activity log');
    }
    return {
      items: resp.data ?? [],
      meta: resp.meta ?? { total: 0, page: 1, page_size: 50 },
    };
  },
};
