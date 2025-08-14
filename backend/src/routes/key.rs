use actix_web::{
    delete, get, put,
    web::{self, Data, Json, Path, Query},
    HttpResponse, Responder, Result,
};
use serde::{Deserialize, Serialize};

use crate::{
    api_types::*,
    db::UsernameAndKey,
    ConnectionPool,
};

use crate::models::PublicUserKey;

#[derive(Serialize)]
struct KeyResponse {
    id: i32,
    key_type: String,
    key_base64: String,
    key_comment: Option<String>,
    username: String,
}

impl From<UsernameAndKey> for KeyResponse {
    fn from(key: UsernameAndKey) -> Self {
        let (username, public_key) = key;
        Self {
            id: public_key.id,
            key_type: public_key.key_type,
            key_base64: public_key.key_base64,
            key_comment: public_key.comment,
            username,
        }
    }
}

#[derive(Serialize)]
struct KeysResponse {
    keys: Vec<KeyResponse>,
}

#[get("")]
pub async fn get_all_keys(
    conn: Data<ConnectionPool>,
    pagination: Query<PaginationQuery>,
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


#[delete("/{id}")]
pub async fn delete_key(
    conn: Data<ConnectionPool>,
    key_id: Path<i32>,
) -> Result<impl Responder> {
    let res =
        web::block(move || PublicUserKey::delete_key(&mut conn.get().unwrap(), *key_id)).await?;

    match res {
        Ok(()) => Ok(HttpResponse::Ok().json(ApiResponse::success_message("Key deleted successfully".to_string()))),
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e))),
    }
}

#[derive(Deserialize)]
struct UpdateKeyCommentRequest {
    comment: String,
}

#[put("/{id}/comment")]
pub async fn update_key_comment(
    conn: Data<ConnectionPool>,
    key_id: Path<i32>,
    json: Json<UpdateKeyCommentRequest>,
) -> Result<impl Responder> {
    let key_id = key_id.into_inner();
    let result = web::block(move || {
        let mut conn = conn.get().unwrap();
        PublicUserKey::update_comment(&mut conn, key_id, &json.comment)
    })
    .await?;

    match result {
        Ok(()) => Ok(HttpResponse::Ok().json(ApiResponse::success_message("Comment updated successfully".to_string()))),
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e))),
    }
}

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(get_all_keys)
        .service(delete_key)
        .service(update_key_comment);
}
