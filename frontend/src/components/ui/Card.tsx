import React, { HTMLAttributes } from 'react';
import { cn } from '../../utils/cn';

interface CardProps extends HTMLAttributes<HTMLDivElement> {
  variant?: 'default' | 'bordered' | 'elevated' | 'glass';
}

const Card = React.forwardRef<HTMLDivElement, CardProps>(({
  className,
  variant = 'default',
  ...props
}, ref) => {
  const variants = {
    default: 'bg-card text-card-foreground border border-border shadow-sm',
    bordered: 'bg-card text-card-foreground border-2 border-border shadow-sm',
    elevated: 'bg-card text-card-foreground shadow-lg border border-border',
    glass: 'bg-white/70 dark:bg-gray-900/70 backdrop-blur-lg border border-white/20 dark:border-gray-700/30 shadow-xl',
  };

  return (
    <div
      ref={ref}
      className={cn(
        'rounded-xl transition-all duration-200',
        variants[variant],
        className
      )}
      {...props}
    />
  );
});

Card.displayName = 'Card';

const CardHeader = React.forwardRef<HTMLDivElement, HTMLAttributes<HTMLDivElement>>(({
  className,
  ...props
}, ref) => (
  <div
    ref={ref}
    className={cn('flex flex-col space-y-1.5 p-6', className)}
    {...props}
  />
));

CardHeader.displayName = 'CardHeader';

const CardTitle = React.forwardRef<HTMLParagraphElement, HTMLAttributes<HTMLHeadingElement>>(({
  className,
  children,
  ...props
}, ref) => (
  <h3
    ref={ref}
    className={cn('text-lg font-semibold leading-none tracking-tight text-foreground', className)}
    {...props}
  >
    {children}
  </h3>
));

CardTitle.displayName = 'CardTitle';

const CardDescription = React.forwardRef<HTMLParagraphElement, HTMLAttributes<HTMLParagraphElement>>(({
  className,
  ...props
}, ref) => (
  <p
    ref={ref}
    className={cn('text-sm text-muted-foreground', className)}
    {...props}
  />
));

CardDescription.displayName = 'CardDescription';

const CardContent = React.forwardRef<HTMLDivElement, HTMLAttributes<HTMLDivElement>>(({
  className,
  ...props
}, ref) => (
  <div
    ref={ref}
    className={cn('p-6 pt-0', className)}
    {...props}
  />
));

CardContent.displayName = 'CardContent';

const CardFooter = React.forwardRef<HTMLDivElement, HTMLAttributes<HTMLDivElement>>(({
  className,
  ...props
}, ref) => (
  <div
    ref={ref}
    className={cn('flex items-center p-6 pt-0', className)}
    {...props}
  />
));

CardFooter.displayName = 'CardFooter';

export { Card, CardHeader, CardFooter, CardTitle, CardDescription, CardContent };