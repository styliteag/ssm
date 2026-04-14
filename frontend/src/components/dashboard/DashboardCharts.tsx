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

// Linear-inspired chart palette: indigo base + accent violet + status tones
const COLORS = ['#5e6ad2', '#7170ff', '#10b981', '#27a644', '#828fff', '#7a7fad'];

// Recharts consumes raw CSS color strings, not class names. Our CSS variables
// are HSL triplets (e.g. "220 11% 4%"), so we wrap them with hsl() for use in
// SVG fills/strokes via a helper.
const cssVar = (name: string) => `hsl(var(--${name}))`;

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
 <CardTitle className="text-base font-w510">{title}</CardTitle>
 </CardHeader>
 <CardContent>
 <div style={{ height: `${height}px` }} className="w-full min-w-0">
 <ResponsiveContainer width="100%" height="100%">
 {type === 'bar' ? (
 <BarChart data={data} margin={{ top: 10, right: 10, left: -20, bottom: 0 }}>
 <CartesianGrid strokeDasharray="3 3" vertical={false} stroke={cssVar('border')} opacity={0.6} />
 <XAxis
 dataKey={categoryKey}
 tick={{ fontSize: 12, fill: cssVar('muted-foreground'), fontWeight: 510 }}
 axisLine={false}
 tickLine={false}
 />
 <YAxis
 tick={{ fontSize: 12, fill: cssVar('muted-foreground'), fontWeight: 510 }}
 axisLine={false}
 tickLine={false}
 />
 <Tooltip
 contentStyle={{
 backgroundColor: cssVar('popover'),
 border: `1px solid ${cssVar('border')}`,
 borderRadius: '8px',
 color: cssVar('foreground'),
 fontSize: '13px',
 fontWeight: 510,
 boxShadow: '0 3px 2px 0 rgba(0,0,0,0.04), 0 1px 1px 0 rgba(0,0,0,0.07), 0 0 1px 0 rgba(0,0,0,0.08)'
 }}
 labelStyle={{ color: cssVar('foreground') }}
 itemStyle={{ color: cssVar('foreground') }}
 cursor={{ fill: 'rgba(255,255,255,0.04)' }}
 />
 <Bar
 dataKey={dataKey}
 fill={cssVar('primary')}
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
 backgroundColor: cssVar('popover'),
 border: `1px solid ${cssVar('border')}`,
 borderRadius: '8px',
 color: cssVar('foreground'),
 fontSize: '13px',
 fontWeight: 510,
 boxShadow: '0 3px 2px 0 rgba(0,0,0,0.04), 0 1px 1px 0 rgba(0,0,0,0.07), 0 0 1px 0 rgba(0,0,0,0.08)'
 }}
 labelStyle={{ color: cssVar('foreground') }}
 itemStyle={{ color: cssVar('foreground') }}
 />
 </PieChart>
 )}
 </ResponsiveContainer>
 </div>
 </CardContent>
 </Card>
 );
};
