import { api } from './base';

export interface Activity {
  id: number;
  type: 'key' | 'host' | 'user' | 'auth';
  action: string;
  target: string;
  user: string;
  timestamp: string;
  metadata?: Record<string, unknown>;
}

interface V2ActivityLogEntry {
  id: number;
  activity_type: string;
  action: string;
  target: string;
  user_id: number | null;
  actor_username: string;
  timestamp: number;
  meta: string | null;
}

const toLegacy = (row: V2ActivityLogEntry): Activity => ({
  id: row.id,
  type: (row.activity_type as Activity['type']) || 'user',
  action: row.action,
  target: row.target,
  user: row.actor_username,
  timestamp: new Date(row.timestamp * 1000).toISOString(),
  metadata: row.meta ? safeParse(row.meta) : undefined,
});

const safeParse = (raw: string): Record<string, unknown> | undefined => {
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === 'object' ? (parsed as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
};

export const activitiesService = {
  async getActivities(
    limit: number = 10,
  ): Promise<{ success: boolean; data?: Activity[]; message?: string }> {
    try {
      const response = await api.get<V2ActivityLogEntry[]>(`/activity-log?page=1&page_size=${limit}`);
      return { success: true, data: (response.data || []).map(toLegacy) };
    } catch (error) {
      return {
        success: false,
        message: error instanceof Error ? error.message : 'Failed to fetch activities',
      };
    }
  },
};
