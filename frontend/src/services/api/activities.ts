import { api } from './base';

export interface Activity {
    id: number;
    type: 'key' | 'host' | 'user' | 'auth';
    action: string;
    target: string;
    user: string;
    timestamp: string;
}

export const activitiesService = {
    /**
     * Get recent activities
     */
    async getActivities(limit: number = 10): Promise<{ success: boolean; data?: Activity[]; message?: string }> {
        try {
            const response = await api.get<Activity[]>(`/activity/activities?limit=${limit}`);
            return {
                success: response.success,
                data: response.data,
                message: response.message
            };
        } catch (error) {
            console.error('Error fetching activities:', error);
            return {
                success: false,
                message: error instanceof Error ? error.message : 'Failed to fetch activities'
            };
        }
    },
};
