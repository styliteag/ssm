use std::sync::Arc;
use std::time::Instant;

use actix_web::{
    delete, get, post, put,
    web::{self, Data, Json, Path, Query},
    HttpRequest, HttpResponse, Responder, Result,
};

use actix_identity::Identity;
use log::error;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::{
    api_types::*,
    db::UserAndOptions,
    logging::RequestLogger,
    routes::ForceUpdateQuery,
    ssh::{CachingSshClient, SshClient, SshFirstConnectionHandler},
    ConnectionPool,
};

use crate::models::{Host, NewHost};

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(get_all_hosts)
        .service(get_host)
        .service(create_host)
        .service(update_host)
        .service(delete_host)
        .service(get_logins)
        .service(authorize_user)
        .service(gen_authorized_keys)
        .service(set_authorized_keys)
        .service(add_host_key)
        .service(delete_authorization)
        .service(list_host_authorizations)
        .service(invalidate_host_cache);
}

#[derive(Serialize, ToSchema)]
pub struct HostResponse {
    id: i32,
    name: String,
    address: String,
    port: i32,
    username: String,
    key_fingerprint: Option<String>,
    jump_via: Option<i32>,
    jumphost_name: Option<String>,
    connection_status: String,
    connection_error: Option<String>,
    authorizations: Vec<UserAndOptions>,
    disabled: bool,
}

impl From<Host> for HostResponse {
    fn from(host: Host) -> Self {
        Self {
            id: host.id,
            name: host.name.clone(),
            address: host.address,
            port: host.port,
            username: host.username,
            key_fingerprint: host.key_fingerprint,
            jump_via: host.jump_via,
            jumphost_name: None, // Will be populated separately if needed
            connection_status: if host.disabled { "disabled".to_string() } else { "unknown".to_string() },
            connection_error: None,
            authorizations: Vec::new(),
            disabled: host.disabled,
        }
    }
}

/// Get all hosts
#[utoipa::path(
    get,
    path = "/api/host",
    tag = "host",
    security(
        ("session_auth" = [])
    ),
    responses(
        (status = 200, description = "List of hosts", body = [HostResponse]),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[get("")]
async fn get_all_hosts(
    req: HttpRequest,
    conn: Data<ConnectionPool>,
    _pagination: Query<PaginationQuery>,
) -> Result<impl Responder> {
    let logger = RequestLogger::new(&req);
    let start_time = Instant::now();
    logger.log_request_start("get_all_hosts");
    let conn_clone = conn.clone();
    let hosts = web::block(move || Host::get_all_hosts(&mut conn_clone.get().unwrap())).await?;
    
    match hosts {
        Ok(hosts) => {
            let mut host_responses: Vec<HostResponse> = Vec::new();
            
            for host in hosts {
                let mut host_response = HostResponse::from(host.clone());
                
                // Set jumphost name if applicable
                if let Some(jumphost_id) = host.jump_via {
                    match Host::get_from_id(conn.get().unwrap(), jumphost_id).await {
                        Ok(Some(jumphost)) => {
                            host_response.jumphost_name = Some(jumphost.name);
                        }
                        Ok(None) => {
                            log::warn!("Jumphost with ID {} not found for host {}", jumphost_id, host.name);
                        }
                        Err(error) => {
                            log::warn!("Failed to get jumphost for host {}: {}", host.name, error);
                        }
                    }
                }
                
                // Don't test SSH connections in bulk - keep as unknown for performance
                // Individual host endpoint will test connections when needed
                
                // Get authorizations for this host
                match host.get_authorized_users(&mut conn.get().unwrap()) {
                    Ok(authorizations) => {
                        host_response.authorizations = authorizations;
                    }
                    Err(error) => {
                        // Log error but don't fail the request
                        log::warn!("Failed to get authorizations for host {}: {}", host.name, error);
                    }
                }
                
                host_responses.push(host_response);
            }
            
            let duration = start_time.elapsed().as_millis() as u64;
            logger.log_request_complete("get_all_hosts", duration, 200);
            Ok(HttpResponse::Ok().json(ApiResponse::success(host_responses)))
        }
        Err(error) => {
            let duration = start_time.elapsed().as_millis() as u64;
            logger.log_request_complete("get_all_hosts", duration, 500);
            Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error)))
        }
    }
}

#[derive(Serialize, ToSchema)]
pub struct LoginsResponse {
    logins: Vec<String>,
}

/// Get available logins for a host
#[utoipa::path(
    get,
    path = "/api/host/{name}/logins",
    security(
        ("session_auth" = [])
    ),
    params(
        ("name" = String, Path, description = "Host name")
    ),
    responses(
        (status = 200, description = "List of available logins", body = LoginsResponse),
        (status = 404, description = "Host not found", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[get("/{name}/logins")]
async fn get_logins(
    conn: Data<ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    host_name: Path<String>,
    update: Query<ForceUpdateQuery>,
) -> Result<impl Responder> {
    let host = Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await;

    match host {
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
        Ok(None) => Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string()))),
        Ok(Some(host)) => {
            // Return empty logins list if host is disabled
            if host.disabled {
                return Ok(HttpResponse::Ok().json(ApiResponse::success(LoginsResponse { logins: Vec::new() })));
            }
            
            let logins = caching_ssh_client
                .get_logins(host, update.force_update.unwrap_or(false))
                .await;
            match logins {
                Ok(logins) => Ok(HttpResponse::Ok().json(ApiResponse::success(LoginsResponse { logins }))),
                Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error.to_string()))),
            }
        }
    }
}

/// Get a host by name
#[utoipa::path(
    get,
    path = "/api/host/{name}",
    security(
        ("session_auth" = [])
    ),
    params(
        ("name" = String, Path, description = "Host name")
    ),
    responses(
        (status = 200, description = "Host details", body = HostResponse),
        (status = 404, description = "Host not found", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[get("/{name}")]
async fn get_host(
    conn: Data<ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    host_name: Path<String>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let host = match Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await {
        Ok(Some(host)) => host,
        Ok(None) => {
            return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string())));
        }
        Err(error) => {
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error)));
        }
    };

    let mut host_response = HostResponse::from(host.clone());
    
    // Set jumphost name if applicable
    if let Some(jumphost_id) = host.jump_via {
        match Host::get_from_id(conn.get().unwrap(), jumphost_id).await {
            Ok(Some(jumphost)) => {
                host_response.jumphost_name = Some(jumphost.name);
            }
            Ok(None) => {
                return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error("Jumphost not found".to_string())));
            }
            Err(error) => {
                return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error)));
            }
        }
    }
    
    // Test SSH connection to get status (skip if host is disabled)
    if host.disabled {
        host_response.connection_status = "disabled".to_string();
        host_response.connection_error = None;
    } else {
        match caching_ssh_client.get_logins(host.clone(), false).await {
            Ok(_logins) => {
                host_response.connection_status = "online".to_string();
                host_response.connection_error = None;
            }
            Err(error) => {
                host_response.connection_status = "offline".to_string();
                host_response.connection_error = Some(error.to_string());
            }
        }
    }
    
    // Get authorizations for this host
    match host.get_authorized_users(&mut conn.get().unwrap()) {
        Ok(authorizations) => {
            host_response.authorizations = authorizations;
        }
        Err(error) => {
            // Log error but don't fail the request
            log::warn!("Failed to get authorizations for host {}: {}", host.name, error);
        }
    }

    Ok(HttpResponse::Ok().json(ApiResponse::success(host_response)))
}

#[derive(Deserialize, ToSchema)]
pub struct AddHostkeyRequest {
    key_fingerprint: Option<String>,
}

#[derive(Deserialize, ToSchema)]
pub struct CreateHostRequest {
    name: String,
    address: String,
    port: u16,
    username: String,
    key_fingerprint: Option<String>,
    jump_via: Option<i32>,
    #[serde(default)]
    disabled: bool,
}

#[derive(Serialize, ToSchema)]
pub struct HostkeyConfirmation {
    host_name: String,
    login: String,
    address: String,
    port: u16,
    key_fingerprint: String,
    jumphost: Option<i32>,
    requires_confirmation: bool,
}

/// Add host key for SSH connection
#[utoipa::path(
    post,
    path = "/api/host/{id}/add_hostkey",
    params(
        ("id" = i32, Path, description = "Host ID")
    ),
    request_body = AddHostkeyRequest,
    responses(
        (status = 200, description = "Host key added successfully", body = HostkeyConfirmation),
        (status = 404, description = "Host not found", body = ApiError)
    )
)]
#[post("/{id}/add_hostkey")]
async fn add_host_key(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
    host_id: Path<i32>,
    json: Json<AddHostkeyRequest>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let host = match Host::get_from_id(conn.get().unwrap(), *host_id).await {
        Ok(Some(h)) => h,
        Ok(None) => return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string()))),
        Err(e) => return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e))),
    };
    let port = host
        .port
        .try_into()
        .expect("Somehow a non u16 port made its way into the database");

    let handler = SshFirstConnectionHandler::new(
        Arc::clone(&conn),
        host.name.clone(),
        host.username.clone(),
        host.address.clone(),
        port,
        host.jump_via,
    )
    .await;

    let handler = match handler {
        Ok(handler) => handler,
        Err(e) => {
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string())));
        }
    };

    let Some(ref key_fingerprint) = json.key_fingerprint else {
        let res = handler.get_hostkey(ssh_client.into_inner()).await;

        let recv_result = match res {
            Ok(receiver) => receiver.await,
            Err(e) => {
                return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string())));
            }
        };

        let key_fingerprint = match recv_result {
            Ok(key_fingerprint) => key_fingerprint,
            Err(e) => {
                error!("Error receiving key: {e}");
                return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string())));
            }
        };

        return Ok(HttpResponse::Ok().json(ApiResponse::success(HostkeyConfirmation {
            host_name: host.name,
            login: host.username,
            address: host.address,
            port,
            jumphost: host.jump_via,
            key_fingerprint,
            requires_confirmation: true,
        })));
    };

    let handler = handler.set_hostkey(key_fingerprint.to_owned());

    let res = handler.try_authenticate(&ssh_client).await;
    if let Err(e) = res {
        return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string())));
    }

    match host.update_fingerprint(&mut conn.get().unwrap(), key_fingerprint.to_owned()) {
        Ok(()) => Ok(HttpResponse::Ok().json(ApiResponse::success_message("Host key updated successfully".to_string()))),
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string()))),
    }
}


/// Create a new host
#[utoipa::path(
    post,
    path = "/api/host",
    request_body = CreateHostRequest,
    responses(
        (status = 201, description = "Host created successfully", body = HostResponse),
        (status = 400, description = "Bad request", body = ApiError)
    )
)]
#[post("")]
async fn create_host(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
    json: Json<CreateHostRequest>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let jumphost = json.jump_via
        .and_then(|host| if host < 0 { None } else { Some(host) });

    let handler = SshFirstConnectionHandler::new(
        Arc::clone(&conn),
        json.name.clone(),
        json.username.clone(),
        json.address.clone(),
        json.port,
        jumphost,
    )
    .await;

    let handler = match handler {
        Ok(handler) => handler,
        Err(e) => {
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string())));
        }
    };

    let Some(key_fingerprint) = json.key_fingerprint.clone() else {
        let res = handler.get_hostkey(ssh_client.into_inner()).await;

        let recv_result = match res {
            Ok(receiver) => receiver.await,
            Err(e) => {
                return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string())));
            }
        };

        let key_fingerprint = match recv_result {
            Ok(key_fingerprint) => key_fingerprint,
            Err(e) => {
                error!("Error receiving key: {e}");
                return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string())));
            }
        };

        return Ok(HttpResponse::Ok().json(ApiResponse::success(HostkeyConfirmation {
            host_name: json.name.clone(),
            login: json.username.clone(),
            address: json.address.clone(),
            port: json.port,
            jumphost: json.jump_via,
            key_fingerprint,
            requires_confirmation: true,
        })));
    };

    // We already have a hostkey, check it
    let handler = handler.set_hostkey(key_fingerprint.clone());
    let res = handler.try_authenticate(&ssh_client).await;
    if let Err(e) = res {
        return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string())));
    }

    let new_host = NewHost {
        name: json.name.clone(),
        address: json.address.clone(),
        port: json.port.into(),
        username: json.username.clone(),
        key_fingerprint: Some(key_fingerprint.clone()),
        jump_via: jumphost,
        disabled: json.disabled,
    };
    let res = web::block(move || Host::add_host(&mut conn.get().unwrap(), &new_host)).await?;

    match res {
        Ok(id) => match ssh_client.install_script_on_host(id).await {
            Ok(()) => Ok(HttpResponse::Created().json(ApiResponse::success_with_message(
                HostResponse::from(Host {
                    id,
                    name: json.name.clone(),
                    address: json.address.clone(),
                    port: json.port.into(),
                    username: json.username.clone(),
                    key_fingerprint: Some(key_fingerprint.clone()),
                    jump_via: jumphost,
                    disabled: json.disabled,
                }),
                "Host created successfully".to_string(),
            ))),
            Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(format!("Failed to install script: {error}")))),
        },
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string()))),
    }
}


#[derive(Deserialize, ToSchema)]
pub struct AuthorizeUserRequest {
    host_id: i32,
    user_id: i32,
    login: String,
    options: Option<String>,
}

/// Authorize a user to access a host
#[utoipa::path(
    post,
    path = "/api/host/user/authorize",
    request_body = AuthorizeUserRequest,
    responses(
        (status = 200, description = "User authorized successfully"),
        (status = 400, description = "Bad request", body = ApiError)
    )
)]
#[post("/user/authorize")]
async fn authorize_user(
    conn: Data<ConnectionPool>,
    json: Json<AuthorizeUserRequest>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let res = web::block(move || {
        Host::authorize_user(
            &mut conn.get().unwrap(),
            json.host_id,
            json.user_id,
            json.login.clone(),
            json.options.clone(),
        )
    })
    .await?;

    match res {
        Ok(()) => Ok(HttpResponse::Ok().json(ApiResponse::success_message("User authorized successfully".to_string()))),
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string()))),
    }
}

#[derive(Deserialize, ToSchema)]
pub struct GenAuthorizedKeysRequest {
    host_name: String,
    login: String,
}

#[derive(Serialize, ToSchema)]
pub struct AuthorizedKeysResponse {
    login: String,
    authorized_keys: String,
    diff_summary: String,
}

/// Generate authorized_keys file for a host
#[utoipa::path(
    post,
    path = "/api/host/gen_authorized_keys",
    request_body = GenAuthorizedKeysRequest,
    responses(
        (status = 200, description = "Authorized keys generated", body = AuthorizedKeysResponse),
        (status = 400, description = "Bad request", body = ApiError)
    )
)]
#[post("/gen_authorized_keys")]
async fn gen_authorized_keys(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
    json: Json<GenAuthorizedKeysRequest>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let host_name = &json.host_name;
    let login = &json.login;

    let host = match Host::get_from_name(conn.get().unwrap(), host_name.to_owned()).await
    {
        Err(error) => {
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error)));
        }
        Ok(None) => {
            return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string())));
        }
        Ok(Some(host)) => host,
    };
    
    // Check if host is disabled
    if host.disabled {
        return Ok(HttpResponse::BadRequest().json(ApiError::bad_request("Cannot generate authorized keys for disabled host".to_string())));
    }
    
    let authorized_keys = host.get_authorized_keys_file_for(&ssh_client, &mut conn.get().unwrap(), login.as_ref());

    let authorized_keys = match authorized_keys {
        Ok(keys) => keys,
        Err(error) => {
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error)));
        }
    };

    let key_diff = match ssh_client
        .key_diff(authorized_keys.as_ref(), host_name.clone(), login.clone())
        .await
    {
        Ok(diff) => diff,
        Err(_) => {
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error("Couldn't calculate key diff".to_string())));
        }
    };

    Ok(HttpResponse::Ok().json(ApiResponse::success(AuthorizedKeysResponse {
        login: login.to_owned(),
        diff_summary: format!("Found {} differences", key_diff.len()),
        authorized_keys,
    })))
}

#[derive(Deserialize, ToSchema)]
pub struct SetAuthorizedKeysRequest {
    login: String,
    authorized_keys: String,
}

/// Set authorized_keys file on a host
#[utoipa::path(
    post,
    path = "/api/host/{name}/set_authorized_keys",
    params(
        ("name" = String, Path, description = "Host name")
    ),
    request_body = SetAuthorizedKeysRequest,
    responses(
        (status = 200, description = "Authorized keys set successfully"),
        (status = 400, description = "Bad request", body = ApiError)
    )
)]
#[post("/{name}/set_authorized_keys")]
async fn set_authorized_keys(
    json: Json<SetAuthorizedKeysRequest>,
    host_name: Path<String>,
    ssh_client: Data<SshClient>,
    conn: Data<ConnectionPool>,
) -> Result<impl Responder> {
    // Check if host exists and is not disabled
    let host = match Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await {
        Err(error) => {
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error)));
        }
        Ok(None) => {
            return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string())));
        }
        Ok(Some(host)) => host,
    };
    
    // Check if host is disabled
    if host.disabled {
        return Ok(HttpResponse::BadRequest().json(ApiError::bad_request("Cannot set authorized keys on disabled host".to_string())));
    }
    
    let res = ssh_client
        .set_authorized_keys(
            host_name.to_string(),
            json.login.clone(),
            json.authorized_keys.clone(),
        )
        .await;

    match res {
        Ok(()) => Ok(HttpResponse::Ok().json(ApiResponse::success_message("Authorized keys applied successfully".to_string()))),
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error.to_string()))),
    }
}


/// Delete a host
#[utoipa::path(
    delete,
    path = "/api/host/{name}",
    params(
        ("name" = String, Path, description = "Host name")
    ),
    responses(
        (status = 200, description = "Host deleted successfully"),
        (status = 404, description = "Host not found", body = ApiError),
        (status = 500, description = "Internal server error", body = ApiError)
    )
)]
#[delete("/{name}")]
async fn delete_host(
    conn: Data<ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    host_name: Path<String>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let host = match Host::get_from_name(conn.get().unwrap(), host_name.to_owned()).await {
        Ok(None) => {
            return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string())));
        }
        Err(error) => {
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(format!("Database error: {error}"))));
        }
        Ok(Some(host)) => host,
    };

    match host.delete(&mut conn.get().unwrap()) {
        Ok(amt) => {
            caching_ssh_client.remove(host_name.as_str()).await;
            Ok(HttpResponse::Ok().json(ApiResponse::success_message(format!("Deleted {amt} record(s)"))))
        }
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(format!("Failed to delete host: {e}")))),
    }
}

#[derive(Serialize, ToSchema)]
pub struct HostAuthorizationsResponse {
    authorizations: Vec<UserAndOptions>,
}

/// List all authorizations for a host
#[utoipa::path(
    get,
    path = "/api/host/{name}/authorizations",
    params(
        ("name" = String, Path, description = "Host name")
    ),
    responses(
        (status = 200, description = "Host authorizations", body = HostAuthorizationsResponse),
        (status = 404, description = "Host not found", body = ApiError)
    )
)]
#[get("/{name}/authorizations")]
async fn list_host_authorizations(
    host_name: Path<String>,
    conn: Data<ConnectionPool>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let host = match Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await {
        Ok(Some(host)) => host,
        Ok(None) => return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string()))),
        Err(error) => return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
    };
    
    let res = web::block(move || host.get_authorized_users(&mut conn.get().unwrap())).await?;

    match res {
        Ok(authorizations) => Ok(HttpResponse::Ok().json(ApiResponse::success(HostAuthorizationsResponse { authorizations }))),
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
    }
}



/// Delete an authorization
#[utoipa::path(
    delete,
    path = "/api/host/authorization/{id}",
    params(
        ("id" = i32, Path, description = "Authorization ID")
    ),
    responses(
        (status = 200, description = "Authorization deleted successfully"),
        (status = 400, description = "Bad request", body = ApiError)
    )
)]
#[delete("/authorization/{id}")]
async fn delete_authorization(
    authorization_id: Path<i32>,
    conn: Data<ConnectionPool>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let res = web::block(move || {
        let mut connection = conn.get().unwrap();
        Host::delete_authorization(&mut connection, *authorization_id)
    })
    .await?;

    match res {
        Ok(()) => Ok(HttpResponse::Ok().json(ApiResponse::success_message("Authorization deleted successfully".to_string()))),
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string()))),
    }
}


/// Invalidate cache for a specific host
#[utoipa::path(
    post,
    path = "/api/host/{name}/cache/invalidate",
    security(
        ("session_auth" = [])
    ),
    params(
        ("name" = String, Path, description = "Host name")
    ),
    responses(
        (status = 200, description = "Cache invalidated successfully"),
        (status = 404, description = "Host not found", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[post("/{name}/cache/invalidate")]
async fn invalidate_host_cache(
    conn: Data<ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    host_name: Path<String>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    // Check if host exists
    let host = match Host::get_from_name(conn.get().unwrap(), host_name.to_string()).await {
        Ok(Some(_host)) => _host,
        Ok(None) => {
            return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string())));
        }
        Err(error) => {
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error)));
        }
    };

    // Invalidate the cache for this host
    caching_ssh_client.invalidate_cache(&host.name).await;
    
    Ok(HttpResponse::Ok().json(ApiResponse::success_message(
        format!("Cache invalidated for host '{}'", host.name)
    )))
}

// Custom deserialization to treat empty strings as None
fn empty_string_as_none<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let s = String::deserialize(deserializer)?;
    if s.trim().is_empty() {
        Ok(None)
    } else {
        Ok(Some(s))
    }
}

fn empty_string_as_none_int<'de, D>(deserializer: D) -> Result<Option<i32>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let s = String::deserialize(deserializer)?;
    if s.trim().is_empty() {
        Ok(None)
    } else {
        s.parse::<i32>().map(Some).map_err(serde::de::Error::custom)
    }
}

#[derive(Deserialize, ToSchema)]
pub struct UpdateHostRequest {
    name: String,
    address: String,
    username: String,
    port: i32,
    #[serde(deserialize_with = "empty_string_as_none")]
    key_fingerprint: Option<String>,
    #[serde(deserialize_with = "empty_string_as_none_int")]
    jump_via: Option<i32>,
    #[serde(default)]
    disabled: bool,
}

/// Update a host
#[utoipa::path(
    put,
    path = "/api/host/{name}",
    params(
        ("name" = String, Path, description = "Host name")
    ),
    request_body = UpdateHostRequest,
    responses(
        (status = 200, description = "Host updated successfully"),
        (status = 400, description = "Bad request", body = ApiError)
    )
)]
#[put("/{name}")]
async fn update_host(
    conn: Data<crate::ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    host_name: Path<String>,
    json: Json<UpdateHostRequest>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let mut db_conn = conn.get().unwrap();
    match Host::update_host(
        &mut db_conn,
        host_name.to_string(),
        json.name.clone(),
        json.address.clone(),
        json.username.clone(),
        json.port,
        json.key_fingerprint.clone(),
        json.jump_via,
        json.disabled,
    ) {
        Ok(()) => {
            // Invalidate cache for both old and new host names (in case of rename)
            caching_ssh_client.invalidate_cache(&host_name).await;
            if json.name != host_name.to_string() {
                caching_ssh_client.invalidate_cache(&json.name).await;
            }
            Ok(HttpResponse::Ok().json(ApiResponse::success_message("Host updated successfully".to_string())))
        },
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string()))),
    }
}
