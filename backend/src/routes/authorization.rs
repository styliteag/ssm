use actix_web::{
    post,
    web::{self, Data, Json},
    HttpResponse, Responder, Result,
};
use actix_identity::Identity;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::{
    api_types::*,
    models::{Host, User},
    routes::require_auth,
    ConnectionPool,
};

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(change_options)
        .service(get_authorization_dialog_data);
}

// #[derive(Deserialize)]
// struct ChangeOptionsForm {
//     authorization_id: i32,
// }
// TODO: do this

/// Change authorization options (TODO: Not implemented)
#[utoipa::path(
    post,
    path = "/api/authorization/change_options",
    security(
        ("session_auth" = [])
    ),
    responses(
        (status = 501, description = "Not implemented", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[post("/change_options")]
async fn change_options(identity: Option<Identity>) -> Result<impl Responder> {
    require_auth(identity)?;
    // TODO: Implement authorization options change
    Ok(HttpResponse::NotImplemented().json(ApiError::new("Not implemented".to_string())))
}

#[derive(Serialize, ToSchema)]
pub struct AuthorizationDialogResponse {
    host_name: String,
    host_id: i32,
    username: String,
    user_id: i32,
    login: String,
    options: Option<String>,
}

#[derive(Deserialize, ToSchema)]
pub struct AuthorizeUserRequest {
    /// Host name in key-manager
    host_name: String,
    /// Username in key-manager
    username: String,
    /// Username on the host
    login: String,
    /// The key options which are already set
    options: Option<String>,
}

/// Get authorization dialog data for user and host
#[utoipa::path(
    post,
    path = "/api/authorization/dialog_data",
    security(
        ("session_auth" = [])
    ),
    request_body = AuthorizeUserRequest,
    responses(
        (status = 200, description = "Authorization dialog data", body = AuthorizationDialogResponse),
        (status = 404, description = "Host or user not found", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[post("/dialog_data")]
async fn get_authorization_dialog_data(
    conn: Data<ConnectionPool>,
    json: Json<AuthorizeUserRequest>,
    identity: Option<Identity>,
) -> Result<impl Responder> {
    require_auth(identity)?;
    let options = json.options.clone();
    let login = json.login.clone();
    let (user, host) = web::block(move || {
        let mut connection = conn.get().unwrap();

        let user = User::get_user(&mut connection, json.username.clone());
        let host = Host::get_from_name_sync(&mut connection, json.host_name.clone());
        (
            user.map(|u| (u.username, u.id)),
            host.map(|h| h.map(|h| (h.name, h.id))),
        )
    })
    .await?;

    let user = match user {
        Ok(u) => u,
        Err(error) => return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
    };

    let host = match host {
        Ok(h) => match h {
            Some(h) => h,
            None => return Ok(HttpResponse::NotFound().json(ApiError::not_found("Host not found".to_string()))),
        },
        Err(error) => return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
    };

    Ok(HttpResponse::Ok().json(ApiResponse::success(AuthorizationDialogResponse {
        host_name: host.0,
        host_id: host.1,
        username: user.0,
        user_id: user.1,
        login,
        options,
    })))
}
