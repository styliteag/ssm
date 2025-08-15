use actix_web::{
    delete, get, post, put,
    web::{self, Data, Json, Path, Query},
    HttpResponse, Responder, Result,
};
use actix_identity::Identity;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

use crate::{
    api_types::*,
    db::UserAndOptions,
    routes::require_auth,
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

#[derive(Serialize, Deserialize, Debug, ToSchema)]
pub struct DeleteUserResponse {
    pub message: String,
}

#[derive(Serialize, Deserialize, Debug, ToSchema)]
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

/// Get all users
#[utoipa::path(
    get,
    path = "/api/users",
    security(
        ("session_auth" = [])
    ),
    responses(
        (status = 200, description = "List of users", body = [UserResponse]),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[get("")]
async fn get_all_users(
    conn: Data<ConnectionPool>,
    _pagination: Query<PaginationQuery>,
    identity: Option<Identity>,
) -> Result<impl Responder> {
    require_auth(identity)?;
    let all_users = web::block(move || User::get_all_users(&mut conn.get().unwrap())).await?;

    match all_users {
        Ok(users) => {
            let user_responses: Vec<UserResponse> = users.into_iter().map(UserResponse::from).collect();
            Ok(HttpResponse::Ok().json(ApiResponse::success(user_responses)))
        }
        Err(error) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error))),
    }
}



/// Get a user by username
#[utoipa::path(
    get,
    path = "/api/users/{name}",
    params(
        ("name" = String, Path, description = "Username")
    ),
    responses(
        (status = 200, description = "User details", body = UserResponse),
        (status = 404, description = "User not found", body = ApiError)
    )
)]
#[get("/{name}")]
async fn get_user(
    conn: Data<ConnectionPool>,
    username: Path<String>,
    identity: Option<Identity>,
) -> Result<impl Responder> {
    require_auth(identity)?;
    let mut conn = conn.clone().get().unwrap();
    let maybe_user = web::block(move || User::get_user(&mut conn, username.to_string())).await?;

    match maybe_user {
        Ok(user) => Ok(HttpResponse::Ok().json(ApiResponse::success(UserResponse::from(user)))),
        Err(error) => Ok(HttpResponse::NotFound().json(ApiError::not_found(error))),
    }
}


/// Create a new user
#[utoipa::path(
    post,
    path = "/api/users",
    request_body = NewUser,
    responses(
        (status = 201, description = "User created successfully"),
        (status = 400, description = "Bad request", body = ApiError)
    )
)]
#[post("")]
async fn create_user(
    conn: Data<ConnectionPool>,
    json: Json<NewUser>,
    identity: Option<Identity>,
) -> Result<impl Responder> {
    require_auth(identity)?;
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


/// Delete a user by username
#[utoipa::path(
    delete,
    path = "/api/users/{username}",
    params(
        ("username" = String, Path, description = "Username to delete")
    ),
    responses(
        (status = 200, description = "User deleted successfully"),
        (status = 400, description = "Bad request", body = ApiError)
    )
)]
#[delete("/{username}")]
async fn delete_user(
    conn: Data<ConnectionPool>,
    username: Path<String>,
    identity: Option<Identity>,
) -> Result<impl Responder> {
    require_auth(identity)?;
    let res = web::block(move || User::delete_user(&mut conn.get().unwrap(), username.as_str())).await?;
    match res {
        Ok(()) => Ok(HttpResponse::Ok().json(ApiResponse::success_message("User deleted successfully".to_string()))),
        Err(e) => Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(e))),
    }
}

#[derive(Serialize, Deserialize, Debug, ToSchema)]
pub struct UserKeyResponse {
    pub id: i32,
    pub key_type: String,
    pub key_base64: String,
    pub key_comment: Option<String>,
    pub fingerprint: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, ToSchema)]
pub struct UserKeysResponse {
    pub keys: Vec<UserKeyResponse>,
}

/// Get SSH keys for a user
#[utoipa::path(
    get,
    path = "/api/users/{username}/keys",
    params(
        ("username" = String, Path, description = "Username")
    ),
    responses(
        (status = 200, description = "User SSH keys", body = UserKeysResponse),
        (status = 404, description = "User not found", body = ApiError)
    )
)]
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

#[derive(Serialize, Deserialize, Debug, ToSchema)]
pub struct UserAuthorizationsResponse {
    pub authorizations: Vec<UserAndOptions>,
}

/// Get user authorizations (hosts they can access)
#[utoipa::path(
    get,
    path = "/api/users/{username}/authorizations",
    params(
        ("username" = String, Path, description = "Username")
    ),
    responses(
        (status = 200, description = "User authorizations", body = UserAuthorizationsResponse),
        (status = 404, description = "User not found", body = ApiError)
    )
)]
#[get("/{username}/authorizations")]
async fn get_user_authorizations(
    conn: Data<ConnectionPool>,
    username: Path<String>,
    identity: Option<Identity>,
) -> Result<impl Responder> {
    require_auth(identity)?;
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

#[derive(Deserialize, ToSchema)]
pub struct AssignKeyRequest {
    user_id: i32,
    key_type: String,
    key_base64: String,
    key_comment: Option<String>,
}

/// Assign an SSH key to a user
#[utoipa::path(
    post,
    path = "/api/users/assign_key",
    request_body = AssignKeyRequest,
    responses(
        (status = 201, description = "Key assigned successfully"),
        (status = 400, description = "Invalid key algorithm", body = ApiError)
    )
)]
#[post("/assign_key")]
async fn assign_key_to_user(
    conn: Data<ConnectionPool>,
    json: Json<AssignKeyRequest>,
    identity: Option<Identity>,
) -> Result<impl Responder> {
    require_auth(identity)?;
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

#[derive(Deserialize, ToSchema)]
pub struct UpdateUserRequest {
    username: String,
    enabled: bool,
}

/// Update a user's information
#[utoipa::path(
    put,
    path = "/api/users/{old_username}",
    params(
        ("old_username" = String, Path, description = "Current username")
    ),
    request_body = UpdateUserRequest,
    responses(
        (status = 200, description = "User updated successfully"),
        (status = 400, description = "Bad request", body = ApiError)
    )
)]
#[put("/{old_username}")]
async fn update_user(
    conn: Data<ConnectionPool>,
    old_username: Path<String>,
    json: Json<UpdateUserRequest>,
    identity: Option<Identity>,
) -> Result<impl Responder> {
    require_auth(identity)?;
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

#[derive(Serialize, ToSchema)]
pub struct AddKeyResponse {
    key: SshPublicKey,
    suggested_action: String,
}

/// Add SSH key dialog (preview key before assignment)
#[utoipa::path(
    post,
    path = "/api/users/add_key",
    request_body = SshPublicKey,
    responses(
        (status = 200, description = "Key preview", body = AddKeyResponse)
    )
)]
#[post("/add_key")]
async fn add_key_dialog(json: Json<SshPublicKey>) -> Result<impl Responder> {
    Ok(HttpResponse::Ok().json(ApiResponse::success(AddKeyResponse {
        key: json.into_inner(),
        suggested_action: "Assign this key to a user".to_string(),
    })))
}
