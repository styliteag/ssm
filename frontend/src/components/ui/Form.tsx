import React, { useState, useCallback } from 'react';
import { cn } from '../../utils/cn';
import Button from './Button';
import Input from './Input';

export interface FormField {
  name: string;
  label: string;
  type?: 'text' | 'email' | 'password' | 'number' | 'tel' | 'url' | 'search' | 'textarea' | 'select';
  placeholder?: string;
  required?: boolean;
  disabled?: boolean;
  helperText?: string;
  options?: Array<{ value: string | number; label: string; disabled?: boolean }>;
  validation?: {
    minLength?: number;
    maxLength?: number;
    min?: number;
    max?: number;
    pattern?: RegExp;
    custom?: (value: unknown) => string | null;
  };
  className?: string;
  inputClassName?: string;
  rows?: number; // For textarea
}

export interface FormProps {
  fields: FormField[];
  onSubmit: (values: Record<string, unknown>) => void | Promise<void>;
  initialValues?: Record<string, unknown>;
  submitText?: string;
  cancelText?: string;
  onCancel?: () => void;
  loading?: boolean;
  disabled?: boolean;
  className?: string;
  formClassName?: string;
  buttonClassName?: string;
  layout?: 'vertical' | 'horizontal' | 'grid';
  gridCols?: number;
  showCancelButton?: boolean;
  validateOnChange?: boolean;
  validateOnBlur?: boolean;
}

export interface FormErrors {
  [key: string]: string | null;
}

const Form: React.FC<FormProps> = ({
  fields,
  onSubmit,
  initialValues = {},
  submitText = 'Submit',
  cancelText = 'Cancel',
  onCancel,
  loading = false,
  disabled = false,
  className,
  formClassName,
  buttonClassName,
  layout = 'vertical',
  gridCols = 2,
  showCancelButton = true,
  validateOnChange = false,
  validateOnBlur = true,
}) => {
  const [values, setValues] = useState<Record<string, unknown>>(() => {
    const initial: Record<string, unknown> = {};
    fields.forEach(field => {
      initial[field.name] = initialValues[field.name] || '';
    });
    return initial;
  });

  const [errors, setErrors] = useState<FormErrors>({});
  const [touched, setTouched] = useState<Record<string, boolean>>({});

  // Validate a single field
  const validateField = useCallback((field: FormField, value: unknown): string | null => {
    if (field.required && (!value || (typeof value === 'string' && !value.trim()))) {
      return `${field.label} is required`;
    }

    if (!value) return null;

    const validation = field.validation;
    if (!validation) return null;

    if (validation.minLength && (value as string).length < validation.minLength) {
      return `${field.label} must be at least ${validation.minLength} characters`;
    }

    if (validation.maxLength && (value as string).length > validation.maxLength) {
      return `${field.label} must be no more than ${validation.maxLength} characters`;
    }

    if (field.type === 'number') {
      const numValue = Number(value);
      if (validation.min !== undefined && numValue < validation.min) {
        return `${field.label} must be at least ${validation.min}`;
      }
      if (validation.max !== undefined && numValue > validation.max) {
        return `${field.label} must be no more than ${validation.max}`;
      }
    }

    if (validation.pattern && !validation.pattern.test(value as string)) {
      return `${field.label} format is invalid`;
    }

    if (validation.custom) {
      return validation.custom(value);
    }

    return null;
  }, []);

  // Validate all fields
  const validateForm = useCallback((): FormErrors => {
    const newErrors: FormErrors = {};
    fields.forEach(field => {
      const error = validateField(field, values[field.name]);
      newErrors[field.name] = error;
    });
    return newErrors;
  }, [fields, values, validateField]);

  // Handle field change
  const handleChange = useCallback((name: string, value: unknown) => {
    setValues(prev => ({ ...prev, [name]: value }));

    if (validateOnChange) {
      const field = fields.find(f => f.name === name);
      if (field) {
        const error = validateField(field, value);
        setErrors(prev => ({ ...prev, [name]: error }));
      }
    }
  }, [validateOnChange, fields, validateField]);

  // Handle field blur
  const handleBlur = useCallback((name: string) => {
    setTouched(prev => ({ ...prev, [name]: true }));

    if (validateOnBlur) {
      const field = fields.find(f => f.name === name);
      if (field) {
        const error = validateField(field, values[name]);
        setErrors(prev => ({ ...prev, [name]: error }));
      }
    }
  }, [validateOnBlur, fields, validateField, values]);

  // Handle form submission
  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    // Mark all fields as touched
    const allTouched: Record<string, boolean> = {};
    fields.forEach(field => {
      allTouched[field.name] = true;
    });
    setTouched(allTouched);

    // Validate all fields
    const formErrors = validateForm();
    setErrors(formErrors);

    // Check if there are any errors
    const hasErrors = Object.values(formErrors).some(error => error !== null);
    if (hasErrors) {
      return;
    }

    // Submit the form
    try {
      await onSubmit(values);
    } catch (error) {
      console.error('Form submission error:', error);
    }
  };

  // Render field based on type
  const renderField = (field: FormField) => {
    const error = touched[field.name] ? errors[field.name] : undefined;
    const commonProps = {
      id: field.name,
      name: field.name,
      disabled: disabled || field.disabled || loading,
      className: field.inputClassName,
    };

    switch (field.type) {
      case 'textarea':
        return (
          <div key={field.name} className={cn('space-y-1', field.className)}>
            <label
              htmlFor={field.name}
              className="block text-sm font-medium text-gray-700 dark:text-gray-300"
            >
              {field.label}
              {field.required && <span className="text-red-500 ml-1">*</span>}
            </label>
            <textarea
              {...commonProps}
              value={(values[field.name] as string) || ''}
              placeholder={field.placeholder}
              rows={field.rows || 3}
              onChange={(e) => handleChange(field.name, e.target.value)}
              onBlur={() => handleBlur(field.name)}
              className={cn(
                'flex w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 placeholder:text-gray-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:cursor-not-allowed disabled:opacity-50',
                'dark:border-gray-600 dark:bg-gray-800 dark:text-gray-100 dark:placeholder:text-gray-500',
                error && 'border-red-500 focus:ring-red-500',
                field.inputClassName
              )}
            />
            {error && (
              <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
            )}
            {field.helperText && !error && (
              <p className="text-sm text-gray-500 dark:text-gray-400">{field.helperText}</p>
            )}
          </div>
        );

      case 'select':
        return (
          <div key={field.name} className={cn('space-y-1', field.className)}>
            <label
              htmlFor={field.name}
              className="block text-sm font-medium text-gray-700 dark:text-gray-300"
            >
              {field.label}
              {field.required && <span className="text-red-500 ml-1">*</span>}
            </label>
            <select
              {...commonProps}
              value={(values[field.name] as string) || ''}
              onChange={(e) => handleChange(field.name, e.target.value)}
              onBlur={() => handleBlur(field.name)}
              className={cn(
                'flex h-10 w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent disabled:cursor-not-allowed disabled:opacity-50',
                'dark:border-gray-600 dark:bg-gray-800 dark:text-gray-100',
                error && 'border-red-500 focus:ring-red-500',
                field.inputClassName
              )}
            >
              <option value="">{field.placeholder || 'Select an option'}</option>
              {field.options?.map((option) => (
                <option
                  key={option.value}
                  value={option.value}
                  disabled={option.disabled}
                >
                  {option.label}
                </option>
              ))}
            </select>
            {error && (
              <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
            )}
            {field.helperText && !error && (
              <p className="text-sm text-gray-500 dark:text-gray-400">{field.helperText}</p>
            )}
          </div>
        );

      default:
        return (
          <div key={field.name} className={field.className}>
            <Input
              {...commonProps}
              type={field.type || 'text'}
              label={field.label}
              value={(values[field.name] as string) || ''}
              placeholder={field.placeholder}
              required={field.required}
              error={error || undefined}
              helperText={field.helperText}
              onChange={(e) => handleChange(field.name, e.target.value)}
              onBlur={() => handleBlur(field.name)}
            />
          </div>
        );
    }
  };

  const layoutClasses = {
    vertical: 'space-y-4',
    horizontal: 'flex flex-wrap gap-4',
    grid: `grid grid-cols-1 md:grid-cols-${gridCols} gap-4`,
  };

  return (
    <div className={cn('w-full', className)}>
      <form onSubmit={handleSubmit} className={cn(formClassName)}>
        <div className={layoutClasses[layout]}>
          {fields.map(renderField)}
        </div>

        <div className={cn(
          'flex items-center justify-end space-x-3 mt-6',
          buttonClassName
        )}>
          {showCancelButton && onCancel && (
            <Button
              type="button"
              variant="secondary"
              onClick={onCancel}
              disabled={loading}
            >
              {cancelText}
            </Button>
          )}
          <Button
            type="submit"
            loading={loading}
            disabled={disabled}
          >
            {submitText}
          </Button>
        </div>
      </form>
    </div>
  );
};

export default Form;