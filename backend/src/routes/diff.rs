use crate::{
    api_types::*,
    ssh::{CachingSshClient, DiffItem, AuthorizedKey},
};
use actix_web::{
    get, post,
    web::{self, Data, Path, Query},
    HttpResponse, Responder, Result,
};

use actix_identity::Identity;
use log::{debug, info, warn, error};
use serde::{Deserialize, Serialize};
use time;
use utoipa::ToSchema;

use crate::{
    ConnectionPool,
};

use crate::models::Host;

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(get_hosts_for_diff)
        .service(get_host_diff)
        .service(get_diff_details)
        .service(sync_host_keys);
}

#[derive(Serialize, ToSchema)]
pub struct DiffResponse {
    host: DiffHostResponse,
    cache_timestamp: String,
    diff_summary: String,
    is_empty: bool,
    total_items: usize,
    logins: Vec<LoginDiff>,
}

#[derive(Serialize, ToSchema)]
pub struct LoginDiff {
    login: String,
    readonly_condition: Option<String>,
    issues: Vec<DiffItemResponse>,
}

#[derive(Serialize, ToSchema)]
pub struct DiffItemResponse {
    #[serde(rename = "type")]
    item_type: String,
    description: String,
    details: Option<serde_json::Value>,
}



#[derive(Serialize, ToSchema)]
pub struct SerializableAuthorizedKey {
    options: String,
    base64: String,
    comment: Option<String>,
    key_type: String,
}

#[derive(Serialize, ToSchema)]
pub struct DetailedDiffResponse {
    host: DiffHostResponse,
    cache_timestamp: String,
    summary: String,
    expected_keys: Vec<ExpectedKeyInfo>,
    logins: Vec<LoginDiff>,
}

#[derive(Serialize, ToSchema)]
pub struct ExpectedKeyInfo {
    username: String,
    login: String,
    key_base64: String,
    key_type: String,
    comment: Option<String>,
    options: Option<String>,
}

#[derive(Serialize, ToSchema)]
pub struct DiffHostResponse {
    id: i32,
    name: String,
    address: String,
}

impl From<Host> for DiffHostResponse {
    fn from(host: Host) -> Self {
        Self {
            id: host.id,
            name: host.name,
            address: host.address,
        }
    }
}

impl From<&AuthorizedKey> for SerializableAuthorizedKey {
    fn from(key: &AuthorizedKey) -> Self {
        Self {
            options: key.options.to_string(),
            base64: key.base64.clone(),
            comment: key.comment.clone(),
            key_type: key.algorithm.to_string(),
        }
    }
}

impl From<&DiffItem> for DiffItemResponse {
    fn from(item: &DiffItem) -> Self {
        match item {
            DiffItem::KeyMissing(key, username) => Self {
                item_type: "key_missing".to_string(),
                description: format!("Missing key for user '{}'", username),
                details: Some(serde_json::json!({
                    "username": username,
                    "key": SerializableAuthorizedKey::from(key)
                })),
            },
            DiffItem::UnknownKey(key) => Self {
                item_type: "unknown_key".to_string(),
                description: "Unknown key found on host".to_string(),
                details: Some(serde_json::json!({
                    "key": SerializableAuthorizedKey::from(key)
                })),
            },
            DiffItem::UnauthorizedKey(key, username) => Self {
                item_type: "unauthorized_key".to_string(),
                description: format!("Key belongs to user '{}' but is not authorized for this host", username),
                details: Some(serde_json::json!({
                    "username": username,
                    "key": SerializableAuthorizedKey::from(key)
                })),
            },
            DiffItem::DuplicateKey(key) => Self {
                item_type: "duplicate_key".to_string(),
                description: "Duplicate key found".to_string(),
                details: Some(serde_json::json!({
                    "key": SerializableAuthorizedKey::from(key)
                })),
            },
            DiffItem::IncorrectOptions(key, expected) => Self {
                item_type: "incorrect_options".to_string(),
                description: "Key has incorrect options".to_string(),
                details: Some(serde_json::json!({
                    "key": SerializableAuthorizedKey::from(key),
                    "expected_options": expected.to_string(),
                    "actual_options": key.options.to_string()
                })),
            },
            DiffItem::FaultyKey(error, line) => Self {
                item_type: "faulty_key".to_string(),
                description: format!("Parse error: {}", error),
                details: Some(serde_json::json!({
                    "error": error,
                    "line": line
                })),
            },
            DiffItem::PragmaMissing => Self {
                item_type: "pragma_missing".to_string(),
                description: "File not yet managed (pragma missing)".to_string(),
                details: None,
            },
        }
    }
}

#[derive(Serialize, ToSchema)]
pub struct DiffHostsResponse {
    hosts: Vec<DiffHostResponse>,
}

/// Get hosts available for diff comparison
#[utoipa::path(
    get,
    path = "/api/diff",
    security(
        ("session_auth" = [])
    ),
    responses(
        (status = 200, description = "Hosts available for diff", body = DiffHostsResponse),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[get("")]
async fn get_hosts_for_diff(conn: Data<ConnectionPool>) -> Result<impl Responder> {
    info!("GET /api/diff - Fetching hosts available for diff comparison");
    debug!("Getting all hosts from database for diff view");
    
    let hosts = web::block(move || Host::get_all_hosts(&mut conn.get().unwrap())).await?;

    match hosts {
        Ok(hosts) => {
            let host_count = hosts.len();
            info!("Successfully retrieved {} hosts for diff comparison", host_count);
            debug!("Host names: {:?}", hosts.iter().map(|h| &h.name).collect::<Vec<_>>());
            
            let host_responses: Vec<DiffHostResponse> = hosts.into_iter().map(DiffHostResponse::from).collect();
            Ok(HttpResponse::Ok().json(ApiResponse::success(DiffHostsResponse { hosts: host_responses })))
        }
        Err(error) => {
            error!("Failed to fetch hosts for diff: {}", error);
            Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error)))
        }
    }
}


#[derive(Deserialize, ToSchema)]
pub struct DiffQuery {
    show_empty: Option<bool>,
    force_update: Option<bool>,
}

/// Get detailed SSH key differences for a specific host
#[utoipa::path(
    get,
    path = "/api/diff/{host_name}",
    security(
        ("session_auth" = [])
    ),
    params(
        ("host_name" = String, Path, description = "Host name"),
        ("show_empty" = Option<bool>, Query, description = "Show empty diff results"),
        ("force_update" = Option<bool>, Query, description = "Force cache refresh")
    ),
    responses(
        (status = 200, description = "Detailed SSH key differences between expected and actual authorized_keys", body = DiffResponse),
        (status = 404, description = "Host not found", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[get("/{host_name}")]
async fn get_host_diff(
    conn: Data<ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    host_name: Path<String>,
    query: Query<DiffQuery>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    info!("GET /api/diff/{} - Starting diff comparison", host_name);
    debug!("Query parameters: force_update={:?}, show_empty={:?}", 
           query.force_update, query.show_empty);
    
    let res = Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await;

    let host = match res {
        Ok(maybe_host) => {
            let Some(host) = maybe_host else {
                warn!("Host '{}' not found in database", host_name);
                return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string())));
            };
            info!("Found host: {} (id: {}, address: {})", host.name, host.id, host.address);
            host
        }
        Err(error) => {
            error!("Database error while looking up host '{}': {}", host_name, error);
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error)));
        }
    };

    let force_update = query.force_update.unwrap_or(false);
    let show_empty = query.show_empty.unwrap_or(false);
    
    info!("Getting diff for host '{}' (force_update: {}, show_empty: {})", 
          host.name, force_update, show_empty);

    let (cache_status, diff_result) = caching_ssh_client
        .get_host_diff(host.clone(), force_update)
        .await;
    
    debug!("Cache status for host '{}': {:?}", host.name, cache_status);

    match diff_result {
        Ok(diff) => {
            let is_empty_diff = diff.is_empty();
            let diff_count = diff.len();
            
            info!("Diff calculation completed for host '{}': {} differences found (empty: {})", 
                  host.name, diff_count, is_empty_diff);
            debug!("Diff details for host '{}': {:?}", host.name, diff);
            
            // Convert diff data to serializable format
            let logins: Vec<LoginDiff> = diff.into_iter().map(|(login, readonly_condition, items)| {
                let issues: Vec<DiffItemResponse> = items.iter().map(DiffItemResponse::from).collect();
                LoginDiff {
                    login,
                    readonly_condition,
                    issues,
                }
            }).collect();
            
            let total_issues: usize = logins.iter().map(|l| l.issues.len()).sum();
            let diff_summary = if is_empty_diff {
                "No differences found".to_string()
            } else {
                format!("Found {} issue(s) across {} login(s)", total_issues, logins.len())
            };
            
            if is_empty_diff && !show_empty {
                info!("Returning empty diff summary for host '{}' (show_empty=false)", host.name);
                Ok(HttpResponse::Ok().json(ApiResponse::success(DiffResponse {
                    host: DiffHostResponse::from(host),
                    cache_timestamp: cache_status.format(&time::format_description::well_known::Rfc3339).unwrap_or_default(),
                    diff_summary,
                    is_empty: true,
                    total_items: 0,
                    logins: vec![],
                })))
            } else {
                info!("Returning full diff for host '{}' with {} items", host.name, total_issues);
                Ok(HttpResponse::Ok().json(ApiResponse::success(DiffResponse {
                    host: DiffHostResponse::from(host),
                    cache_timestamp: cache_status.format(&time::format_description::well_known::Rfc3339).unwrap_or_default(),
                    diff_summary,
                    is_empty: is_empty_diff,
                    total_items: total_issues,
                    logins,
                })))
            }
        }
        Err(error) => {
            error!("Failed to get diff for host '{}': {}", host.name, error);
            Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error.to_string())))
        }
    }
}


/// Get detailed diff information for a host, including raw authorized_keys content
#[utoipa::path(
    get,
    path = "/api/diff/{name}/details",
    security(
        ("session_auth" = [])
    ),
    params(
        ("name" = String, Path, description = "Host name"),
        ("force_update" = Option<bool>, Query, description = "Force cache refresh")
    ),
    responses(
        (status = 200, description = "Host diff details with expected vs actual authorized_keys comparison", body = DetailedDiffResponse),
        (status = 404, description = "Host not found", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[get("/{name}/details")]
async fn get_diff_details(
    conn: Data<ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    host_name: Path<String>,
    query: Query<DiffQuery>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    info!("GET /api/diff/{}/details - Fetching detailed diff with raw content", host_name);
    debug!("Looking up host '{}' for detailed diff analysis", host_name);
    
    let res = Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await;

    let host = match res {
        Ok(maybe_host) => {
            let Some(host) = maybe_host else {
                warn!("Host '{}' not found for details view", host_name);
                return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string())));
            };
            info!("Found host for details: {} (id: {}, address: {})", host.name, host.id, host.address);
            host
        }
        Err(error) => {
            error!("Database error while looking up host '{}' for details: {}", host_name, error);
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error)));
        }
    };

    let force_update = query.force_update.unwrap_or(false);
    
    // Get the expected authorized keys from database
    let expected_keys = match host.get_authorized_keys(&mut conn.get().unwrap()) {
        Ok(keys) => keys,
        Err(error) => {
            error!("Failed to get expected keys for host '{}': {}", host.name, error);
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error.to_string())));
        }
    };

    // Get actual state and diff
    let (cache_status, diff_result) = caching_ssh_client
        .get_host_diff(host.clone(), force_update)
        .await;

    match diff_result {
        Ok(diff) => {
            info!("Successfully retrieved detailed diff for host '{}'", host.name);
            
            // Convert diff data to serializable format
            let logins: Vec<LoginDiff> = diff.into_iter().map(|(login, readonly_condition, items)| {
                let issues: Vec<DiffItemResponse> = items.iter().map(DiffItemResponse::from).collect();
                LoginDiff {
                    login,
                    readonly_condition,
                    issues,
                }
            }).collect();
            
            let total_issues: usize = logins.iter().map(|l| l.issues.len()).sum();
            
            Ok(HttpResponse::Ok().json(ApiResponse::success(DetailedDiffResponse {
                host: DiffHostResponse::from(host),
                cache_timestamp: cache_status.format(&time::format_description::well_known::Rfc3339).unwrap_or_default(),
                summary: format!("Found {} issue(s) across {} login(s)", total_issues, logins.len()),
                expected_keys: expected_keys.into_iter().map(|k| ExpectedKeyInfo {
                    username: k.username,
                    login: k.login,
                    key_base64: k.key.key_base64,
                    key_type: k.key.key_type,
                    comment: k.key.comment,
                    options: k.options,
                }).collect(),
                logins,
            })))
        }
        Err(error) => {
            error!("Failed to get detailed diff for host '{}': {}", host.name, error);
            Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error.to_string())))
        }
    }
}

/// Sync SSH keys to a host by applying all pending changes
#[utoipa::path(
    post,
    path = "/api/diff/{name}/sync",
    security(
        ("session_auth" = [])
    ),
    params(
        ("name" = String, Path, description = "Host name")
    ),
    responses(
        (status = 200, description = "SSH keys synchronized successfully", body = ApiResponse<serde_json::Value>),
        (status = 404, description = "Host not found", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError),
        (status = 500, description = "Sync operation failed", body = ApiError)
    )
)]
#[post("/{name}/sync")]
async fn sync_host_keys(
    conn: Data<ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    host_name: Path<String>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    info!("POST /api/diff/{}/sync - Starting SSH key synchronization", host_name);
    
    let res = Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await;

    let host = match res {
        Ok(maybe_host) => {
            let Some(host) = maybe_host else {
                warn!("Host '{}' not found for sync operation", host_name);
                return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string())));
            };
            info!("Found host for sync: {} (id: {}, address: {})", host.name, host.id, host.address);
            host
        }
        Err(error) => {
            error!("Database error while looking up host '{}' for sync: {}", host_name, error);
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error)));
        }
    };

    info!("Applying SSH key synchronization for host '{}'", host.name);

    // Apply the sync changes using the SSH client
    match caching_ssh_client.apply_host_changes(host.clone()).await {
        Ok(_) => {
            info!("Successfully synchronized SSH keys for host '{}'", host.name);
            
            // Clear the cache for this host to force a fresh diff on next request
            caching_ssh_client.invalidate_cache(&host.name).await;
            
            Ok(HttpResponse::Ok().json(ApiResponse::success(serde_json::json!({
                "message": format!("SSH keys synchronized successfully for host '{}'", host.name),
                "host": host.name
            }))))
        }
        Err(error) => {
            error!("Failed to sync SSH keys for host '{}': {}", host.name, error);
            Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(format!("Sync operation failed: {}", error))))
        }
    }
}
