import React, { ButtonHTMLAttributes, forwardRef } from 'react';
import { cn } from '../../utils/cn';

interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: 'primary' | 'secondary' | 'danger' | 'ghost' | 'outline' | 'gradient';
  size?: 'sm' | 'md' | 'lg';
  loading?: boolean;
  leftIcon?: React.ReactNode;
  rightIcon?: React.ReactNode;
}

const Button = forwardRef<HTMLButtonElement, ButtonProps>(({
  className,
  variant = 'primary',
  size = 'md',
  loading = false,
  disabled,
  leftIcon,
  rightIcon,
  children,
  ...props
}, ref) => {
  // Linear's buttons: transparency over solid fills, whisper-thin borders, weight 510
  const baseClasses = 'inline-flex items-center justify-center font-w510 transition-colors duration-200 cursor-pointer focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-0 disabled:pointer-events-none disabled:opacity-50 disabled:cursor-not-allowed';

  const variants = {
    primary: 'bg-primary text-primary-foreground hover:bg-[hsl(240_100%_72%)] dark:hover:bg-[hsl(240_100%_75%)]',
    secondary: 'bg-secondary text-secondary-foreground border border-border hover:bg-surface-4',
    danger: 'bg-destructive text-destructive-foreground hover:bg-destructive/90',
    ghost: 'bg-white/[0.02] text-foreground border border-border hover:bg-white/[0.05] dark:bg-white/[0.02] dark:hover:bg-white/[0.05]',
    outline: 'border border-border bg-transparent text-foreground hover:bg-white/[0.04] dark:hover:bg-white/[0.04]',
    gradient: 'bg-primary text-primary-foreground hover:bg-[hsl(240_100%_72%)]',
  };

  const sizes = {
    sm: 'h-8 px-3 text-sm rounded-md',
    md: 'h-9 px-4 text-sm rounded-md',
    lg: 'h-11 px-5 text-base rounded-md',
  };

  return (
    <button
      className={cn(
        baseClasses,
        variants[variant],
        sizes[size],
        className
      )}
      ref={ref}
      disabled={disabled || loading}
      {...props}
    >
      {loading && (
        <svg
          className="mr-2 h-4 w-4 animate-spin"
          xmlns="http://www.w3.org/2000/svg"
          fill="none"
          viewBox="0 0 24 24"
        >
          <circle
            className="opacity-25"
            cx="12"
            cy="12"
            r="10"
            stroke="currentColor"
            strokeWidth="4"
          />
          <path
            className="opacity-75"
            fill="currentColor"
            d="m4 12a8 8 0 0 1 8-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 0 1 4 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
          />
        </svg>
      )}
      {!loading && leftIcon && <span className="mr-2">{leftIcon}</span>}
      {children}
      {!loading && rightIcon && <span className="ml-2">{rightIcon}</span>}
    </button>
  );
});

Button.displayName = 'Button';

export default Button;