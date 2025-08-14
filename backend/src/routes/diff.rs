use crate::{
    api_types::*,
    ssh::CachingSshClient,
};
use actix_web::{
    get,
    web::{self, Data, Path, Query},
    HttpResponse, Responder, Result,
};
use serde::{Deserialize, Serialize};

use crate::{
    ConnectionPool,
};

use crate::models::Host;

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(get_hosts_for_diff)
        .service(get_host_diff)
        .service(get_diff_details);
}

#[derive(Serialize)]
struct DiffResponse {
    host_name: String,
    logins: Vec<LoginDiff>,
}

#[derive(Serialize)]
struct LoginDiff {
    login: String,
    changes: Vec<String>,
}

#[derive(Serialize)]
struct AuthorizedKeysResponse {
    login: String,
    content: String,
}

#[derive(Serialize)]
struct KeyComparisonResponse {
    identical: bool,
    changes: Vec<String>,
}

#[derive(Serialize)]
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

#[derive(Serialize)]
struct DiffHostsResponse {
    hosts: Vec<DiffHostResponse>,
}

#[get("")]
async fn get_hosts_for_diff(conn: Data<ConnectionPool>) -> Result<impl Responder> {
    let hosts = web::block(move || Host::get_all_hosts(&mut conn.get().unwrap())).await?;

    match hosts {
        Ok(hosts) => {
            let host_responses: Vec<DiffHostResponse> = hosts.into_iter().map(DiffHostResponse::from).collect();
            Ok(HttpResponse::Ok().json(ApiResponse::success(DiffHostsResponse { hosts: host_responses })))
        }
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
    }
}


#[derive(Deserialize)]
struct DiffQuery {
    show_empty: Option<bool>,
    force_update: Option<bool>,
}

#[get("/{host_name}")]
async fn get_host_diff(
    conn: Data<ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    host_name: Path<String>,
    query: Query<DiffQuery>,
) -> Result<impl Responder> {
    let res = Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await;

    let host = match res {
        Ok(maybe_host) => {
            let Some(host) = maybe_host else {
                return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string())));
            };
            host
        }
        Err(error) => return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
    };

    let force_update = query.force_update.unwrap_or(false);
    let show_empty = query.show_empty.unwrap_or(false);

    let (_, diff_result) = caching_ssh_client
        .get_host_diff(host.clone(), force_update)
        .await;

    match diff_result {
        Ok(diff) => {
            let is_empty_diff = diff.is_empty();
            if is_empty_diff && !show_empty {
                Ok(HttpResponse::Ok().json(ApiResponse::success(serde_json::json!({
                    "host": DiffHostResponse::from(host),
                    "diff_summary": "No differences found",
                    "is_empty": true,
                    "total_items": 0
                }))))
            } else {
                Ok(HttpResponse::Ok().json(ApiResponse::success(serde_json::json!({
                    "host": DiffHostResponse::from(host),
                    "diff_summary": format!("Found {} differences", diff.len()),
                    "is_empty": is_empty_diff,
                    "total_items": diff.len()
                }))))
            }
        }
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error.to_string()))),
    }
}


#[get("/{name}/details")]
async fn get_diff_details(
    conn: Data<ConnectionPool>,
    host_name: Path<String>,
) -> Result<impl Responder> {
    match Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await {
        Ok(host) => {
            let Some(host) = host else {
                return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string())));
            };
            Ok(HttpResponse::Ok().json(ApiResponse::success(DiffHostResponse::from(host))))
        }
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
    }
}
