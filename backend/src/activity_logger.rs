use actix_identity::Identity;
use log::error;

use crate::routes::activity_log::log_activity;
use crate::DbConnection;

/// Extract username from Identity, defaulting to "system" if not present
pub fn extract_username(identity: Option<&Identity>) -> String {
    match identity {
        Some(id) => id.id().unwrap_or_else(|_| "system".to_string()),
        None => "system".to_string(),
    }
}

/// Log a host-related activity
pub fn log_host_event(
    conn: &mut DbConnection,
    identity: Option<&Identity>,
    action: &str,
    host_name: &str,
) {
    let username = extract_username(identity);
    if let Err(e) = log_activity(conn, "host", action, host_name, &username) {
        error!("Failed to log host activity: {}", e);
    }
}

/// Log a user-related activity
pub fn log_user_event(
    conn: &mut DbConnection,
    identity: Option<&Identity>,
    action: &str,
    target_username: &str,
) {
    let username = extract_username(identity);
    if let Err(e) = log_activity(conn, "user", action, target_username, &username) {
        error!("Failed to log user activity: {}", e);
    }
}

/// Log a key-related activity
pub fn log_key_event(
    conn: &mut DbConnection,
    identity: Option<&Identity>,
    action: &str,
    key_info: &str,
) {
    let username = extract_username(identity);
    if let Err(e) = log_activity(conn, "key", action, key_info, &username) {
        error!("Failed to log key activity: {}", e);
    }
}

/// Log an authentication event
pub fn log_auth_event(
    conn: &mut DbConnection,
    identity: Option<&Identity>,
    action: &str,
    details: &str,
) {
    let username = extract_username(identity);
    if let Err(e) = log_activity(conn, "auth", action, details, &username) {
        error!("Failed to log auth activity: {}", e);
    }
}


