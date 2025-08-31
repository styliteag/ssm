import { type ClassValue, clsx } from 'clsx';

export function cn(...inputs: ClassValue[]) {
  return clsx(inputs);
}

// Alternative without clsx dependency - using just string concatenation
export function cnSimple(...classes: (string | undefined | null | false)[]): string {
  return classes.filter(Boolean).join(' ');
}