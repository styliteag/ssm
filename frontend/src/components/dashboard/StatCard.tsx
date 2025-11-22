import React from 'react';
import { LucideIcon } from 'lucide-react';
import { Card, CardContent } from '../ui/Card';
import { cn } from '../../utils/cn';

interface StatCardProps {
    title: string;
    value: number | string;
    icon: LucideIcon;
    description?: string;
    trend?: {
        value: number;
        isPositive: boolean;
    };
    className?: string;
    iconColor?: string;
    gradient?: string;
}

export const StatCard: React.FC<StatCardProps> = ({
    title,
    value,
    icon: Icon,
    description,
    trend,
    className,
    iconColor = "text-primary",
    gradient
}) => {
    return (
        <Card className={cn("overflow-hidden relative transition-all duration-200 hover:shadow-md", className)}>
            {gradient && (
                <div className={cn("absolute inset-0 opacity-10", gradient)} />
            )}
            <CardContent className="p-6 relative z-10">
                <div className="flex items-center justify-between space-x-4">
                    <div className="flex items-center justify-center w-12 h-12 rounded-full bg-background/80 shadow-sm ring-1 ring-border">
                        <Icon className={cn("w-6 h-6", iconColor)} />
                    </div>
                    {trend && (
                        <div className={cn(
                            "flex items-center text-xs font-medium px-2 py-1 rounded-full",
                            trend.isPositive
                                ? "text-green-700 bg-green-100 dark:text-green-400 dark:bg-green-900/30"
                                : "text-red-700 bg-red-100 dark:text-red-400 dark:bg-red-900/30"
                        )}>
                            {trend.isPositive ? '+' : ''}{trend.value}%
                        </div>
                    )}
                </div>

                <div className="mt-4">
                    <h3 className="text-sm font-medium text-muted-foreground">{title}</h3>
                    <div className="flex items-baseline mt-1">
                        <span className="text-2xl font-bold tracking-tight text-foreground">
                            {value}
                        </span>
                    </div>
                    {description && (
                        <p className="mt-1 text-xs text-muted-foreground/80">
                            {description}
                        </p>
                    )}
                </div>
            </CardContent>
        </Card>
    );
};
