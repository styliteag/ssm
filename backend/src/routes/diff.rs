use crate::{
    api_types::*,
    ssh::CachingSshClient,
};
use actix_web::{
    get,
    web::{self, Data, Path, Query},
    HttpResponse, Responder, Result,
};
use log::{debug, info, warn, error};
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::{
    ConnectionPool,
};

use crate::models::Host;

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(get_hosts_for_diff)
        .service(get_host_diff)
        .service(get_diff_details);
}

#[derive(Serialize, ToSchema)]
pub struct DiffResponse {
    host_name: String,
    logins: Vec<LoginDiff>,
}

#[derive(Serialize, ToSchema)]
pub struct LoginDiff {
    login: String,
    changes: Vec<String>,
}

#[derive(Serialize, ToSchema)]
pub struct AuthorizedKeysResponse {
    login: String,
    content: String,
}

#[derive(Serialize, ToSchema)]
pub struct KeyComparisonResponse {
    identical: bool,
    changes: Vec<String>,
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

#[derive(Serialize, ToSchema)]
pub struct DiffHostsResponse {
    hosts: Vec<DiffHostResponse>,
}

/// Get hosts available for diff comparison
#[utoipa::path(
    get,
    path = "/api/diff",
    responses(
        (status = 200, description = "Hosts available for diff", body = DiffHostsResponse)
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

/// Get SSH key differences for a specific host
#[utoipa::path(
    get,
    path = "/api/diff/{host_name}",
    params(
        ("host_name" = String, Path, description = "Host name")
    ),
    responses(
        (status = 200, description = "SSH key differences", body = DiffResponse),
        (status = 404, description = "Host not found", body = ApiError)
    )
)]
#[get("/{host_name}")]
async fn get_host_diff(
    conn: Data<ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    host_name: Path<String>,
    query: Query<DiffQuery>,
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
            
            if is_empty_diff && !show_empty {
                info!("Returning empty diff summary for host '{}' (show_empty=false)", host.name);
                Ok(HttpResponse::Ok().json(ApiResponse::success(serde_json::json!({
                    "host": DiffHostResponse::from(host),
                    "diff_summary": "No differences found",
                    "is_empty": true,
                    "total_items": 0
                }))))
            } else {
                info!("Returning full diff for host '{}' with {} items", host.name, diff_count);
                Ok(HttpResponse::Ok().json(ApiResponse::success(serde_json::json!({
                    "host": DiffHostResponse::from(host),
                    "diff_summary": format!("Found {} differences", diff.len()),
                    "is_empty": is_empty_diff,
                    "total_items": diff.len()
                }))))
            }
        }
        Err(error) => {
            error!("Failed to get diff for host '{}': {}", host.name, error);
            Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error.to_string())))
        }
    }
}


/// Get detailed diff information for a host
#[utoipa::path(
    get,
    path = "/api/diff/{name}/details",
    params(
        ("name" = String, Path, description = "Host name")
    ),
    responses(
        (status = 200, description = "Host diff details", body = DiffHostResponse),
        (status = 404, description = "Host not found", body = ApiError)
    )
)]
#[get("/{name}/details")]
async fn get_diff_details(
    conn: Data<ConnectionPool>,
    host_name: Path<String>,
) -> Result<impl Responder> {
    info!("GET /api/diff/{}/details - Fetching host details for diff", host_name);
    debug!("Looking up host '{}' in database for details view", host_name);
    
    match Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await {
        Ok(host) => {
            let Some(host) = host else {
                warn!("Host '{}' not found for details view", host_name);
                return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string())));
            };
            info!("Successfully retrieved details for host: {} (id: {}, address: {})", 
                  host.name, host.id, host.address);
            Ok(HttpResponse::Ok().json(ApiResponse::success(DiffHostResponse::from(host))))
        }
        Err(error) => {
            error!("Database error while fetching details for host '{}': {}", host_name, error);
            Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error)))
        }
    }
}
