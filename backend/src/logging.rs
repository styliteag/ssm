/// Standardized logging utilities for consistent logging across the application
///
/// This module provides logging functions that:
/// - Use appropriate log levels (debug, info, warn, error)
/// - Include structured context information
/// - Avoid logging sensitive data
/// - Follow consistent formatting
use log::{debug, error, info, warn};
use actix_web::HttpRequest;

/// Standardized request logging with security considerations
pub struct RequestLogger<'a> {
    req: &'a HttpRequest,
}

impl<'a> RequestLogger<'a> {
    pub fn new(req: &'a HttpRequest) -> Self {
        Self { req }
    }

    /// Log API request start with sanitized information
    pub fn log_request_start(&self, operation: &str) {
        let method = self.req.method();
        let path = self.req.path();
        let user_agent = self.req
            .headers()
            .get("user-agent")
            .and_then(|h| h.to_str().ok())
            .unwrap_or("unknown");

        // Sanitize path to avoid logging sensitive parameters
        let sanitized_path = if path.contains("password") || path.contains("token") || path.contains("key") {
            format!("{}/[FILTERED]", path.split('/').take(3).collect::<Vec<_>>().join("/"))
        } else {
            path.to_string()
        };

        debug!(
            "API_REQUEST_START method={} path={} operation={} user_agent={}",
            method, sanitized_path, operation, user_agent
        );
    }

    /// Log API request completion
    pub fn log_request_complete(&self, operation: &str, duration_ms: u64, status: u16) {
        let method = self.req.method();
        let path = self.req.path();

        let sanitized_path = if path.contains("password") || path.contains("token") || path.contains("key") {
            format!("{}/[FILTERED]", path.split('/').take(3).collect::<Vec<_>>().join("/"))
        } else {
            path.to_string()
        };

        let level = if status >= 500 {
            log::Level::Error
        } else if status >= 400 {
            log::Level::Warn
        } else {
            log::Level::Info
        };

        match level {
            log::Level::Error => error!(
                "API_REQUEST_COMPLETE method={} path={} operation={} status={} duration_ms={}",
                method, sanitized_path, operation, status, duration_ms
            ),
            log::Level::Warn => warn!(
                "API_REQUEST_COMPLETE method={} path={} operation={} status={} duration_ms={}",
                method, sanitized_path, operation, status, duration_ms
            ),
            _ => debug!(
                "API_REQUEST_COMPLETE method={} path={} operation={} status={} duration_ms={}",
                method, sanitized_path, operation, status, duration_ms
            ),
        }
    }
}

/// Database operation logging
pub struct DatabaseLogger;

impl DatabaseLogger {
    /// Log successful database operations
    pub fn log_operation_success(operation: &str, table: &str, record_count: Option<usize>) {
        // Use warn! for operations that change data (write operations)
        // Use debug! for read operations
        let is_write_operation = matches!(operation, "insert" | "update" | "delete" | "add_host" | "authorize_user" | "delete_host" | "delete_authorization");

        match (is_write_operation, record_count) {
            (true, Some(count)) => warn!("DB_OPERATION_SUCCESS operation={} table={} records={}", operation, table, count),
            (true, None) => warn!("DB_OPERATION_SUCCESS operation={} table={}", operation, table),
            (false, Some(count)) => debug!("DB_OPERATION_SUCCESS operation={} table={} records={}", operation, table, count),
            (false, None) => debug!("DB_OPERATION_SUCCESS operation={} table={}", operation, table),
        }
    }

    /// Log database operation failures
    pub fn log_operation_error(operation: &str, table: &str, error: &str) {
        error!("DB_OPERATION_ERROR operation={} table={} error={}", operation, table, error);
    }

    /// Log connection pool events
    pub fn log_connection_event(event: &str, pool_size: usize) {
        match event {
            "exhausted" => warn!("DB_CONNECTION_EXHAUSTED pool_size={}", pool_size),
            "restored" => debug!("DB_CONNECTION_RESTORED pool_size={}", pool_size),
            _ => debug!("DB_CONNECTION_EVENT event={} pool_size={}", event, pool_size),
        }
    }
}

/// Authentication logging (with security considerations)
pub struct AuthLogger;

impl AuthLogger {
    /// Log successful authentication
    pub fn log_auth_success(username: &str, method: &str) {
        warn!("AUTH_SUCCESS username={} method={}", username, method);
    }

    /// Log authentication failure (avoid logging passwords)
    pub fn log_auth_failure(username: Option<&str>, method: &str, reason: &str) {
        let safe_username = username.unwrap_or("unknown");
        warn!("AUTH_FAILURE username={} method={} reason={}", safe_username, method, reason);
    }

    /// Log session events
    pub fn log_session_event(event: &str, session_id: &str) {
        match event {
            "created" => debug!("SESSION_CREATED id={}", session_id),
            "destroyed" => debug!("SESSION_DESTROYED id={}", session_id),
            "expired" => debug!("SESSION_EXPIRED id={}", session_id),
            _ => debug!("SESSION_EVENT event={} id={}", event, session_id),
        }
    }
}

/// SSH operation logging
pub struct SshLogger;

impl SshLogger {
    /// Log SSH connection attempts
    pub fn log_connection_attempt(host: &str, username: &str) {
        debug!("SSH_CONNECTION_ATTEMPT host={} username={}", host, username);
    }

    /// Log SSH connection success
    pub fn log_connection_success(host: &str, username: &str) {
        debug!("SSH_CONNECTION_SUCCESS host={} username={}", host, username);
    }

    /// Log SSH connection failure
    pub fn log_connection_failure(host: &str, username: &str, error: &str) {
        warn!("SSH_CONNECTION_FAILURE host={} username={} error={}", host, username, error);
    }

    /// Log SSH key synchronization
    pub fn log_key_sync(host: &str, username: &str, keys_added: usize, keys_removed: usize) {
        // SSH key synchronization changes the state of remote hosts - use warn!
        if keys_added > 0 || keys_removed > 0 {
            warn!(
                "SSH_KEY_SYNC_COMPLETED host={} username={} added={} removed={}",
                host, username, keys_added, keys_removed
            );
        } else {
            debug!(
                "SSH_KEY_SYNC_COMPLETED host={} username={} added={} removed={}",
                host, username, keys_added, keys_removed
            );
        }
    }
}

/// Security event logging
pub struct SecurityLogger;

impl SecurityLogger {
    /// Log security events
    pub fn log_security_event(event: &str, details: &str, severity: &str) {
        match severity {
            "critical" => error!("SECURITY_EVENT_CRITICAL event={} details={}", event, details),
            "high" => error!("SECURITY_EVENT_HIGH event={} details={}", event, details),
            "medium" => warn!("SECURITY_EVENT_MEDIUM event={} details={}", event, details),
            "low" => info!("SECURITY_EVENT_LOW event={} details={}", event, details),
            _ => info!("SECURITY_EVENT event={} details={} severity={}", event, details, severity),
        }
    }


    /// Log suspicious activity
    pub fn log_suspicious_activity(activity: &str, ip: &str, details: &str) {
        warn!("SUSPICIOUS_ACTIVITY activity={} ip={} details={}", activity, ip, details);
    }
}

/// Application lifecycle logging
pub struct AppLogger;

impl AppLogger {
    /// Log application startup
    pub fn log_startup(component: &str, version: &str) {
        info!("APP_STARTUP component={} version={}", component, version);
    }

    /// Log application shutdown
    pub fn log_shutdown(component: &str, reason: &str) {
        info!("APP_SHUTDOWN component={} reason={}", component, reason);
    }

    /// Log configuration loading
    pub fn log_config_loaded(source: &str, keys_loaded: usize) {
        info!("CONFIG_LOADED source={} keys={}", source, keys_loaded);
    }

    /// Log configuration errors
    #[allow(dead_code)]
    pub fn log_config_error(error: &str, fatal: bool) {
        if fatal {
            error!("CONFIG_ERROR_FATAL error={}", error);
        } else {
            warn!("CONFIG_ERROR_RECOVERABLE error={}", error);
        }
    }
}
