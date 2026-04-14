import React from 'react';
import { CheckCircle, AlertCircle, Info, X } from 'lucide-react';
import { useNotifications } from '../../contexts/NotificationContext';
import { NotificationState } from '../../types';
import { cn } from '../../utils/cn';

const NotificationToast: React.FC = () => {
  const { notifications, removeNotification } = useNotifications();

  const getNotificationIcon = (type: NotificationState['type']) => {
    switch (type) {
      case 'success':
        return <CheckCircle size={20} />;
      case 'error':
        return <AlertCircle size={20} />;
      case 'warning':
        return <AlertCircle size={20} />;
      case 'info':
        return <Info size={20} />;
      default:
        return <Info size={20} />;
    }
  };

  // Linear toasts: translucent popover surface, colored accent icon
  const getNotificationStyles = (type: NotificationState['type']) => {
    switch (type) {
      case 'success':
        return 'bg-popover border-success/30 text-foreground [&_svg]:text-success';
      case 'error':
        return 'bg-popover border-destructive/40 text-foreground [&_svg]:text-destructive';
      case 'warning':
        return 'bg-popover border-warning/40 text-foreground [&_svg]:text-warning';
      case 'info':
        return 'bg-popover border-primary/40 text-foreground [&_svg]:text-primary';
      default:
        return 'bg-popover border-border text-foreground';
    }
  };

  if (notifications.length === 0) {
    return null;
  }

  return (
    <div className="fixed top-4 right-4 z-50 space-y-2 max-w-sm w-full">
      {notifications.map((notification) => (
        <div
          key={notification.id}
          className={cn(
            'animate-in slide-in-from-right-full duration-300 rounded-lg border p-4 shadow-linear-dialog backdrop-blur-sm',
            getNotificationStyles(notification.type)
          )}
        >
          <div className="flex items-start space-x-3">
            <div className="flex-shrink-0">
              {getNotificationIcon(notification.type)}
            </div>
            <div className="flex-1 min-w-0">
              <h4 className="text-sm font-w590">
                {notification.title}
              </h4>
              {notification.message && (
                <p className="text-sm mt-1 text-muted-foreground tracking-body-lg">
                  {notification.message}
                </p>
              )}
            </div>
            <button
              onClick={() => removeNotification(notification.id)}
              className="flex-shrink-0 opacity-60 hover:opacity-100 transition-opacity"
            >
              <X size={16} />
            </button>
          </div>
        </div>
      ))}
    </div>
  );
};

export default NotificationToast;