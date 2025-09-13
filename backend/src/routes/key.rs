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
    let all_keys =
        web::block(move || PublicUserKey::get_all_keys_with_username(&mut conn.get().unwrap()))
            .await?;

    match all_keys {
        Ok(keys) => {
            let key_responses: Vec<KeyResponse> = keys.into_iter().map(KeyResponse::from).collect();
            Ok(HttpResponse::Ok().json(ApiResponse::success(KeysResponse { keys: key_responses })))
        }
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
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
    let res =
        web::block(move || PublicUserKey::delete_key(&mut conn.get().unwrap(), *key_id)).await?;

    match res {
        Ok(()) => Ok(HttpResponse::Ok().json(ApiResponse::success_message("Key deleted successfully".to_string()))),
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e))),
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
    let result = web::block(move || {
        let mut conn = conn.get().unwrap();

        // Update name if provided
        if let Some(name) = &json.name {
            use crate::db::key::update_key_name;
            update_key_name(&mut conn, key_id, name)?;
        }

        // Update extra_comment if provided
        if let Some(extra_comment) = &json.extra_comment {
            use crate::db::key::update_key_extra_comment;
            update_key_extra_comment(&mut conn, key_id, extra_comment)?;
        }

        Ok(())
    })
    .await?;

    match result {
        Ok(()) => Ok(HttpResponse::Ok().json(ApiResponse::success_message("Key information updated successfully".to_string()))),
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e))),
    }
}

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(web::resource("").route(web::get().to(get_all_keys)))
        .service(delete_key)
        .service(update_key_comment);
}
