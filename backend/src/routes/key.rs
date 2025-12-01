use actix_web::{
    delete, put,
    web::{self, Data, Json, Path, Query},
    HttpResponse, Responder, Result,
};

use actix_identity::Identity;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::{
    api_types::*,
    db::UsernameAndKey,
    ConnectionPool,
};
use crate::routes::{get_db_conn, get_db_conn_string, internal_error_response};

use crate::activity_logger;

use crate::models::PublicUserKey;

#[derive(Serialize, ToSchema)]
pub struct KeyResponse {
    id: i32,
    key_type: String,
    key_base64: String,
    key_name: Option<String>,
    extra_comment: Option<String>,
    username: String,
}

impl From<UsernameAndKey> for KeyResponse {
    fn from(key: UsernameAndKey) -> Self {
        let (username, public_key) = key;
        Self {
            id: public_key.id,
            key_type: public_key.key_type,
            key_base64: public_key.key_base64,
            key_name: public_key.name,
            extra_comment: public_key.extra_comment,
            username,
        }
    }
}

#[derive(Serialize, ToSchema)]
pub struct KeysResponse {
    keys: Vec<KeyResponse>,
}

/// Get all SSH keys
#[utoipa::path(
    get,
    path = "/api/key",
    security(
        ("session_auth" = [])
    ),
    responses(
        (status = 200, description = "List of SSH keys", body = KeysResponse),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
pub async fn get_all_keys(
    conn: Data<ConnectionPool>,
    _pagination: Query<PaginationQuery>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let conn_clone = conn.clone();
    let all_keys =
        web::block(move || {
            let mut db_conn = get_db_conn_string(&conn_clone)?;
            PublicUserKey::get_all_keys_with_username(&mut db_conn)
        })
            .await?;

    match all_keys {
        Ok(keys) => {
            let key_responses: Vec<KeyResponse> = keys.into_iter().map(KeyResponse::from).collect();
            Ok(HttpResponse::Ok().json(ApiResponse::success(KeysResponse { keys: key_responses })))
        }
        Err(error) => internal_error_response(error),
    }
}


/// Delete an SSH key by ID
#[utoipa::path(
    delete,
    path = "/api/key/{id}",
    security(
        ("session_auth" = [])
    ),
    params(
        ("id" = i32, Path, description = "Key ID")
    ),
    responses(
        (status = 200, description = "Key deleted successfully"),
        (status = 400, description = "Bad request", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[delete("/{id}")]
pub async fn delete_key(
    conn: Data<ConnectionPool>,
    key_id: Path<i32>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let conn_clone = conn.clone();
    let key_id_val = *key_id;
    let key_id_for_log = *key_id;
    let res =
        web::block(move || {
            let mut db_conn = get_db_conn_string(&conn_clone)?;
            PublicUserKey::delete_key(&mut db_conn, key_id_val)
        }).await?;

    match res {
        Ok(()) => {
            let mut db_conn = get_db_conn(&conn)?;
            activity_logger::log_key_event(
                &mut db_conn,
                _identity.as_ref(),
                "Deleted SSH key",
                &format!("ID {}", key_id_for_log),
            );
            Ok(HttpResponse::Ok().json(ApiResponse::success_message("Key deleted successfully".to_string())))
        },
        Err(e) => internal_error_response(e),
    }
}

#[derive(Deserialize, ToSchema)]
pub struct UpdateKeyCommentRequest {
    name: Option<String>,
    extra_comment: Option<String>,
}

/// Update SSH key comment
#[utoipa::path(
    put,
    path = "/api/key/{id}/comment",
    security(
        ("session_auth" = [])
    ),
    params(
        ("id" = i32, Path, description = "Key ID")
    ),
    request_body = UpdateKeyCommentRequest,
    responses(
        (status = 200, description = "Key comment updated successfully"),
        (status = 400, description = "Bad request", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[put("/{id}/comment")]
pub async fn update_key_comment(
    conn: Data<ConnectionPool>,
    key_id: Path<i32>,
    json: Json<UpdateKeyCommentRequest>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let key_id = key_id.into_inner();
    let conn_clone = conn.clone();
    let key_id_for_log = key_id;
    let result = web::block(move || -> Result<(), String> {
        let mut db_conn = get_db_conn_string(&conn_clone)?;

        // Update name if provided
        if let Some(name) = &json.name {
            use crate::db::key::update_key_name;
            update_key_name(&mut db_conn, key_id, name)
                .map_err(|e| format!("Database error: {}", e))?;
        }

        // Update extra_comment if provided
        if let Some(extra_comment) = &json.extra_comment {
            use crate::db::key::update_key_extra_comment;
            update_key_extra_comment(&mut db_conn, key_id, extra_comment)
                .map_err(|e| format!("Database error: {}", e))?;
        }

        Ok(())
    })
    .await?;

    match result {
        Ok(()) => {
            let mut db_conn = get_db_conn(&conn)?;
            activity_logger::log_key_event(
                &mut db_conn,
                _identity.as_ref(),
                "Updated SSH key",
                &format!("ID {}", key_id_for_log),
            );
            Ok(HttpResponse::Ok().json(ApiResponse::success_message("Key information updated successfully".to_string())))
        },
        Err(e) => internal_error_response(e),
    }
}

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(web::resource("").route(web::get().to(get_all_keys)))
        .service(delete_key)
        .service(update_key_comment);
}
