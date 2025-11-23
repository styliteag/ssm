import React from 'react';
import {
    BarChart,
    Bar,
    XAxis,
    YAxis,
    CartesianGrid,
    Tooltip,
    ResponsiveContainer,
    PieChart,
    Pie,
    Cell
} from 'recharts';
import { Card, CardContent, CardHeader, CardTitle } from '../ui/Card';
import { cn } from '../../utils/cn';

interface ChartProps {
    data: any[];
    type: 'bar' | 'pie';
    title: string;
    dataKey: string;
    categoryKey?: string;
    colors?: string[];
    className?: string;
    height?: number;
}

const COLORS = ['#3b82f6', '#10b981', '#f59e0b', '#ef4444', '#8b5cf6'];

export const DashboardChart: React.FC<ChartProps> = ({
    data,
    type,
    title,
    dataKey,
    categoryKey = 'name',
    colors = COLORS,
    className,
    height = 250
}) => {
    return (
        <Card className={cn("h-full", className)}>
            <CardHeader>
                <CardTitle className="text-base font-medium">{title}</CardTitle>
            </CardHeader>
            <CardContent>
                <div style={{ height: `${height}px` }} className="w-full min-w-0">
                    <ResponsiveContainer width="100%" height="100%">
                        {type === 'bar' ? (
                            <BarChart data={data} margin={{ top: 10, right: 10, left: -20, bottom: 0 }}>
                                <CartesianGrid strokeDasharray="3 3" vertical={false} stroke="var(--border)" opacity={0.5} />
                                <XAxis
                                    dataKey={categoryKey}
                                    tick={{ fontSize: 12, fill: 'var(--muted-foreground)' }}
                                    axisLine={false}
                                    tickLine={false}
                                />
                                <YAxis
                                    tick={{ fontSize: 12, fill: 'var(--muted-foreground)' }}
                                    axisLine={false}
                                    tickLine={false}
                                />
                                <Tooltip
                                    contentStyle={{
                                        backgroundColor: 'var(--background)',
                                        borderColor: 'var(--border)',
                                        borderRadius: 'var(--radius)',
                                        color: 'var(--foreground)'
                                    }}
                                    cursor={{ fill: 'var(--muted)', opacity: 0.2 }}
                                />
                                <Bar
                                    dataKey={dataKey}
                                    fill="var(--primary)"
                                    radius={[4, 4, 0, 0]}
                                    barSize={30}
                                />
                            </BarChart>
                        ) : (
                            <PieChart>
                                <Pie
                                    data={data}
                                    cx="50%"
                                    cy="50%"
                                    innerRadius={60}
                                    outerRadius={80}
                                    paddingAngle={5}
                                    dataKey={dataKey}
                                >
                                    {data.map((_, index) => (
                                        <Cell key={`cell-${index}`} fill={colors[index % colors.length]} />
                                    ))}
                                </Pie>
                                <Tooltip
                                    contentStyle={{
                                        backgroundColor: 'var(--background)',
                                        borderColor: 'var(--border)',
                                        borderRadius: 'var(--radius)',
                                        color: 'var(--foreground)'
                                    }}
                                />
                            </PieChart>
                        )}
                    </ResponsiveContainer>
                </div>
            </CardContent>
        </Card>
    );
};
