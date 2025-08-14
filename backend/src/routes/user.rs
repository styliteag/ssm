use actix_web::{
    delete, get, post, put,
    web::{self, Data, Json, Path, Query},
    HttpResponse, Responder, Result,
};
use serde::{Deserialize, Serialize};

use crate::{
    api_types::*,
    db::UserAndOptions,
    ssh::SshPublicKey,
    ConnectionPool,
};

use crate::models::{NewPublicUserKey, NewUser, PublicUserKey, User};

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(get_all_users)
        .service(get_user)
        .service(create_user)
        .service(update_user)
        .service(delete_user)
        .service(get_user_keys)
        .service(get_user_authorizations)
        .service(assign_key_to_user)
        .service(add_key_dialog);
}

#[derive(Serialize, Deserialize, Debug)]
pub struct DeleteUserResponse {
    pub message: String,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct UserResponse {
    pub id: i32,
    pub username: String,
    pub enabled: bool,
}

impl From<User> for UserResponse {
    fn from(user: User) -> Self {
        Self {
            id: user.id,
            username: user.username,
            enabled: user.enabled,
        }
    }
}

#[get("")]
async fn get_all_users(
    conn: Data<ConnectionPool>,
    _pagination: Query<PaginationQuery>,
) -> Result<impl Responder> {
    let all_users = web::block(move || User::get_all_users(&mut conn.get().unwrap())).await?;

    match all_users {
        Ok(users) => {
            let user_responses: Vec<UserResponse> = users.into_iter().map(UserResponse::from).collect();
            Ok(HttpResponse::Ok().json(ApiResponse::success(user_responses)))
        }
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
    }
}



#[get("/{name}")]
async fn get_user(
    conn: Data<ConnectionPool>,
    username: Path<String>,
) -> Result<impl Responder> {
    let mut conn = conn.clone().get().unwrap();
    let maybe_user = web::block(move || User::get_user(&mut conn, username.to_string())).await?;

    match maybe_user {
        Ok(user) => Ok(HttpResponse::Ok().json(ApiResponse::success(UserResponse::from(user)))),
        Err(error) => Ok(HttpResponse::NotFound().json(ApiError::not_found(error))),
    }
}


#[post("")]
async fn create_user(
    conn: Data<ConnectionPool>,
    json: Json<NewUser>,
) -> Result<impl Responder> {
    let new_user = json.into_inner();

    let res = web::block(move || User::add_user(&mut conn.get().unwrap(), new_user)).await?;
    match res {
        Ok(user_id) => {
            Ok(HttpResponse::Created().json(ApiResponse::success_with_message(
                serde_json::json!({"id": user_id}),
                "User created successfully".to_string(),
            )))
        }
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e))),
    }
}


#[delete("/{username}")]
async fn delete_user(
    conn: Data<ConnectionPool>,
    username: Path<String>,
) -> Result<impl Responder> {
    let res = web::block(move || User::delete_user(&mut conn.get().unwrap(), username.as_str())).await?;
    match res {
        Ok(()) => Ok(HttpResponse::Ok().json(ApiResponse::success_message("User deleted successfully".to_string()))),
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e))),
    }
}

#[derive(Serialize, Deserialize, Debug)]
pub struct UserKeyResponse {
    pub id: i32,
    pub key_type: String,
    pub key_base64: String,
    pub key_comment: Option<String>,
    pub fingerprint: Option<String>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct UserKeysResponse {
    pub keys: Vec<UserKeyResponse>,
}

#[get("/{username}/keys")]
async fn get_user_keys(
    conn: Data<ConnectionPool>,
    username: Path<String>,
) -> Result<impl Responder> {
    let maybe_user_keys = web::block(move || {
        let mut connection = conn.get().unwrap();
        let user = User::get_user(&mut connection, username.to_string())?;
        user.get_keys(&mut connection)
    })
    .await?;

    match maybe_user_keys {
        Ok(keys) => {
            let key_responses: Vec<UserKeyResponse> = keys
                .into_iter()
                .map(|key| {
                    let fingerprint = russh::keys::PublicKey::try_from(&key)
                        .map(|k| k.fingerprint(russh::keys::HashAlg::Sha256).to_string())
                        .ok();

                    UserKeyResponse {
                        id: key.id,
                        key_type: key.key_type,
                        key_base64: key.key_base64,
                        key_comment: key.comment,
                        fingerprint,
                    }
                })
                .collect();
            Ok(HttpResponse::Ok().json(ApiResponse::success(UserKeysResponse { keys: key_responses })))
        }
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
    }
}

#[derive(Serialize, Deserialize, Debug)]
pub struct UserAuthorizationsResponse {
    pub authorizations: Vec<UserAndOptions>,
}

#[get("/{username}/authorizations")]
async fn get_user_authorizations(
    conn: Data<ConnectionPool>,
    username: Path<String>,
) -> Result<impl Responder> {
    let maybe_user_auth = web::block(move || {
        let mut connection = conn.get().unwrap();
        let user = User::get_user(&mut connection, username.to_string())?;
        user.get_authorizations(&mut connection)
    })
    .await?;

    match maybe_user_auth {
        Ok(authorizations) => Ok(HttpResponse::Ok().json(ApiResponse::success(UserAuthorizationsResponse { authorizations }))),
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
    }
}

#[derive(Deserialize)]
struct AssignKeyRequest {
    user_id: i32,
    key_type: String,
    key_base64: String,
    key_comment: Option<String>,
}

#[post("/assign_key")]
async fn assign_key_to_user(
    conn: Data<ConnectionPool>,
    json: Json<AssignKeyRequest>,
) -> Result<impl Responder> {
    // Validate that the key type is valid
    let algorithm = match russh::keys::Algorithm::new(&json.key_type) {
        Ok(algo) => algo,
        Err(_) => {
            return Ok(HttpResponse::BadRequest().json(ApiError::bad_request(
                "Invalid key algorithm".to_string(),
            )));
        }
    };

    let new_key = NewPublicUserKey::new(
        algorithm,
        json.key_base64.clone(),
        json.key_comment.clone(),
        json.user_id,
    );

    let res = web::block(move || PublicUserKey::add_key(&mut conn.get().unwrap(), new_key)).await?;

    match res {
        Ok(()) => Ok(HttpResponse::Created().json(ApiResponse::success_message("Key assigned successfully".to_string()))),
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e))),
    }
}

#[derive(Deserialize)]
struct UpdateUserRequest {
    username: String,
    enabled: bool,
}

#[put("/{old_username}")]
async fn update_user(
    conn: Data<ConnectionPool>,
    old_username: Path<String>,
    json: Json<UpdateUserRequest>,
) -> Result<impl Responder> {
    let mut conn = conn.get().unwrap();
    match User::update_user(
        &mut conn,
        &old_username,
        &json.username,
        json.enabled,
    ) {
        Ok(_) => Ok(HttpResponse::Ok().json(ApiResponse::success_message("User updated successfully".to_string()))),
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
    }
}

#[derive(Serialize)]
struct AddKeyResponse {
    key: SshPublicKey,
    suggested_action: String,
}

#[post("/add_key")]
async fn add_key_dialog(json: Json<SshPublicKey>) -> Result<impl Responder> {
    Ok(HttpResponse::Ok().json(ApiResponse::success(AddKeyResponse {
        key: json.into_inner(),
        suggested_action: "Assign this key to a user".to_string(),
    })))
}
