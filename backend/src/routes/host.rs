use std::sync::Arc;

use actix_web::{
    delete, get, post, put,
    web::{self, Data, Json, Path, Query},
    HttpResponse, Responder, Result,
};
use log::error;
use serde::{Deserialize, Serialize};

use crate::{
    api_types::*,
    db::UserAndOptions,
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
        .service(list_host_authorizations);
}

#[derive(Serialize)]
struct HostResponse {
    id: i32,
    name: String,
    address: String,
    port: i32,
    username: String,
    key_fingerprint: Option<String>,
    jump_via: Option<i32>,
    jumphost_name: Option<String>,
}

impl From<Host> for HostResponse {
    fn from(host: Host) -> Self {
        Self {
            id: host.id,
            name: host.name,
            address: host.address,
            port: host.port,
            username: host.username,
            key_fingerprint: host.key_fingerprint,
            jump_via: host.jump_via,
            jumphost_name: None, // Will be populated separately if needed
        }
    }
}

#[get("")]
async fn get_all_hosts(
    conn: Data<ConnectionPool>,
    pagination: Query<PaginationQuery>,
) -> Result<impl Responder> {
    let hosts = web::block(move || Host::get_all_hosts(&mut conn.get().unwrap())).await?;
    
    match hosts {
        Ok(hosts) => {
            let host_responses: Vec<HostResponse> = hosts.into_iter().map(HostResponse::from).collect();
            Ok(HttpResponse::Ok().json(ApiResponse::success(host_responses)))
        }
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
    }
}

#[derive(Serialize)]
struct LoginsResponse {
    logins: Vec<String>,
}

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

#[get("/{name}")]
async fn get_host(
    conn: Data<ConnectionPool>,
    host_name: Path<String>,
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

    Ok(HttpResponse::Ok().json(ApiResponse::success(host_response)))
}

#[derive(Deserialize)]
struct AddHostkeyRequest {
    key_fingerprint: Option<String>,
}

#[derive(Deserialize)]
struct CreateHostRequest {
    name: String,
    address: String,
    port: u16,
    username: String,
    key_fingerprint: Option<String>,
    jump_via: Option<i32>,
}

#[derive(Serialize)]
struct HostkeyConfirmation {
    host_name: String,
    login: String,
    address: String,
    port: u16,
    key_fingerprint: String,
    jumphost: Option<i32>,
    requires_confirmation: bool,
}

#[post("/{id}/add_hostkey")]
async fn add_host_key(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
    host_id: Path<i32>,
    json: Json<AddHostkeyRequest>,
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


#[post("")]
async fn create_host(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
    json: Json<CreateHostRequest>,
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
        key_fingerprint: key_fingerprint.clone(),
        jump_via: jumphost,
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
                }),
                "Host created successfully".to_string(),
            ))),
            Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(format!("Failed to install script: {error}")))),
        },
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string()))),
    }
}


#[derive(Deserialize)]
struct AuthorizeUserRequest {
    host_id: i32,
    user_id: i32,
    login: String,
    options: Option<String>,
}

#[post("/user/authorize")]
async fn authorize_user(
    conn: Data<ConnectionPool>,
    json: Json<AuthorizeUserRequest>,
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

#[derive(Deserialize)]
struct GenAuthorizedKeysRequest {
    host_name: String,
    login: String,
}

#[derive(Serialize)]
struct AuthorizedKeysResponse {
    login: String,
    authorized_keys: String,
    diff_summary: String,
}

#[post("/gen_authorized_keys")]
async fn gen_authorized_keys(
    conn: Data<ConnectionPool>,
    ssh_client: Data<SshClient>,
    json: Json<GenAuthorizedKeysRequest>,
) -> Result<impl Responder> {
    let host_name = &json.host_name;
    let login = &json.login;

    let authorized_keys = match Host::get_from_name(conn.get().unwrap(), host_name.to_owned()).await
    {
        Err(error) => {
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error)));
        }
        Ok(None) => {
            return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string())));
        }
        Ok(Some(host)) => {
            host.get_authorized_keys_file_for(&ssh_client, &mut conn.get().unwrap(), login.as_ref())
        }
    };

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

#[derive(Deserialize)]
struct SetAuthorizedKeysRequest {
    login: String,
    authorized_keys: String,
}

#[post("/{name}/set_authorized_keys")]
async fn set_authorized_keys(
    json: Json<SetAuthorizedKeysRequest>,
    host_name: Path<String>,
    ssh_client: Data<SshClient>,
) -> Result<impl Responder> {
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

#[derive(Serialize)]
struct DeleteHostResponse {
    authorizations: Vec<UserAndOptions>,
    affected_hosts: Vec<String>,
}

#[derive(Deserialize)]
struct HostDeleteRequest {
    #[serde(default)]
    confirm: bool,
}

#[delete("/{name}")]
async fn delete_host(
    conn: Data<ConnectionPool>,
    caching_ssh_client: Data<CachingSshClient>,
    json: Json<HostDeleteRequest>,
    host_name: Path<String>,
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

    if json.confirm {
        return match host.delete(&mut conn.get().unwrap()) {
            Ok(amt) => {
                caching_ssh_client.remove(host_name.as_str()).await;
                Ok(HttpResponse::Ok().json(ApiResponse::success_message(format!("Deleted {amt} record(s)"))))
            }
            Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(format!("Failed to delete host: {e}")))),
        };
    }

    let mut connection = conn.get().unwrap();

    let res = host
        .get_authorized_users(&mut connection)
        .and_then(|authorizations| {
            host.get_dependant_hosts(&mut connection)
                .map(|hosts| (authorizations, hosts))
        });

    // TODO: resolve authorizations of dependant hosts
    match res {
        Ok((authorizations, affected_hosts)) => Ok(HttpResponse::Ok().json(ApiResponse::success(DeleteHostResponse {
            authorizations,
            affected_hosts,
        }))),
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(format!("Failed to get authorizations: {error}")))),
    }
}

#[derive(Serialize)]
struct HostAuthorizationsResponse {
    authorizations: Vec<UserAndOptions>,
}

#[get("/{name}/authorizations")]
async fn list_host_authorizations(
    host_name: Path<String>,
    conn: Data<ConnectionPool>,
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

#[derive(Deserialize)]
struct DeleteAuthorizationRequest {
    authorization_id: i32,
}

#[delete("/authorization/{id}")]
async fn delete_authorization(
    authorization_id: Path<i32>,
    conn: Data<ConnectionPool>,
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

#[derive(Deserialize)]
struct UpdateHostRequest {
    name: String,
    address: String,
    username: String,
    port: i32,
    #[serde(deserialize_with = "empty_string_as_none")]
    key_fingerprint: Option<String>,
    #[serde(deserialize_with = "empty_string_as_none_int")]
    jump_via: Option<i32>,
}

#[put("/{name}")]
async fn update_host(
    conn: Data<crate::ConnectionPool>,
    host_name: Path<String>,
    json: Json<UpdateHostRequest>,
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
    ) {
        Ok(()) => Ok(HttpResponse::Ok().json(ApiResponse::success_message("Host updated successfully".to_string()))),
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e.to_string()))),
    }
}
