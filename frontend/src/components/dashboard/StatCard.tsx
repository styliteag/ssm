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
        <Card className={cn("overflow-hidden relative transition-colors duration-200 hover:bg-white/[0.04] cursor-pointer", className)}>
            {gradient && (
                <div className={cn("absolute inset-0 opacity-[0.04]", gradient)} />
            )}
            <CardContent className="p-6 relative z-10">
                <div className="flex items-center justify-between space-x-4">
                    <div className="flex items-center justify-center w-10 h-10 rounded-md bg-white/[0.03] border border-border">
                        <Icon className={cn("w-5 h-5", iconColor)} />
                    </div>
                    {trend && (
                        <div className={cn(
                            "flex items-center text-xs font-w510 px-2 py-0.5 rounded-full border",
                            trend.isPositive
                                ? "text-success border-success/30 bg-success/10"
                                : "text-destructive border-destructive/30 bg-destructive/10"
                        )}>
                            {trend.isPositive ? '+' : ''}{trend.value}%
                        </div>
                    )}
                </div>

                <div className="mt-5">
                    <h3 className="text-xs font-w510 text-muted-foreground uppercase tracking-wider">{title}</h3>
                    <div className="flex items-baseline mt-2">
                        <span className="text-[32px] leading-none font-w510 tracking-h1 text-foreground">
                            {value}
                        </span>
                    </div>
                    {description && (
                        <p className="mt-2 text-xs text-muted-foreground/80 tracking-body-lg">
                            {description}
                        </p>
                    )}
                </div>
            </CardContent>
        </Card>
    );
};
