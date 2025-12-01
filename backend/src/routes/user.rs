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
    ssh::SshPublicKey,
    ConnectionPool,
};
use crate::routes::{get_db_conn, get_db_conn_string, internal_error_response, not_found_response, bad_request_response};

use crate::activity_logger;

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
pub struct UserResponse {
    pub id: i32,
    pub username: String,
    pub enabled: bool,
    pub comment: Option<String>,
}

impl From<User> for UserResponse {
    fn from(user: User) -> Self {
        Self {
            id: user.id,
            username: user.username,
            enabled: user.enabled,
            comment: user.comment,
        }
    }
}

/// Get all users
#[utoipa::path(
    get,
    path = "/api/user",
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
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let conn_clone = conn.clone();
    let all_users = web::block(move || {
        let mut db_conn = get_db_conn_string(&conn_clone)?;
        User::get_all_users(&mut db_conn)
    }).await?;

    match all_users {
        Ok(users) => {
            let user_responses: Vec<UserResponse> = users.into_iter().map(UserResponse::from).collect();
            Ok(HttpResponse::Ok().json(ApiResponse::success(user_responses)))
        }
        Err(error) => internal_error_response(error),
    }
}



/// Get a user by username
#[utoipa::path(
    get,
    path = "/api/user/{name}",
    security(
        ("session_auth" = [])
    ),
    params(
        ("name" = String, Path, description = "Username")
    ),
    responses(
        (status = 200, description = "User details", body = UserResponse),
        (status = 404, description = "User not found", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[get("/{name}")]
async fn get_user(
    conn: Data<ConnectionPool>,
    username: Path<String>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let conn_clone = conn.clone();
    let username_str = username.to_string();
    let username_for_error = username_str.clone();
    let maybe_user = web::block(move || {
        let mut db_conn = get_db_conn_string(&conn_clone)?;
        User::get_user(&mut db_conn, username_str)
    }).await?;

    match maybe_user {
        Ok(user) => Ok(HttpResponse::Ok().json(ApiResponse::success(UserResponse::from(user)))),
        Err(_error) => not_found_response(format!("User '{}' not found", username_for_error)),
    }
}


/// Create a new user
#[utoipa::path(
    post,
    path = "/api/user",
    security(
        ("session_auth" = [])
    ),
    request_body = NewUser,
    responses(
        (status = 201, description = "User created successfully"),
        (status = 400, description = "Bad request", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[post("")]
async fn create_user(
    conn: Data<ConnectionPool>,
    json: Json<NewUser>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let new_user = json.into_inner();

    let conn_clone = conn.clone();
    let username_for_log = new_user.username.clone();
    
    let res = web::block(move || {
        let mut db_conn = get_db_conn_string(&conn_clone)?;
        User::add_user(&mut db_conn, new_user)
    }).await?;
    match res {
        Ok(user_id) => {
            let mut db_conn = get_db_conn(&conn)?;
            activity_logger::log_user_event(
                &mut db_conn,
                _identity.as_ref(),
                "Created user",
                &username_for_log,
            );
            Ok(HttpResponse::Created().json(ApiResponse::success_with_message(
                serde_json::json!({"id": user_id}),
                "User created successfully".to_string(),
            )))
        }
        Err(e) => internal_error_response(e),
    }
}


/// Delete a user by username
#[utoipa::path(
    delete,
    path = "/api/user/{username}",
    security(
        ("session_auth" = [])
    ),
    params(
        ("username" = String, Path, description = "Username to delete")
    ),
    responses(
        (status = 200, description = "User deleted successfully"),
        (status = 400, description = "Bad request", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[delete("/{username}")]
async fn delete_user(
    conn: Data<ConnectionPool>,
    username: Path<String>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let conn_clone = conn.clone();
    let username_str = username.to_string();
    let username_for_log = username_str.clone();
    
    let res = web::block(move || {
        let mut db_conn = get_db_conn_string(&conn_clone)?;
        User::delete_user(&mut db_conn, &username_str)
    }).await?;
    match res {
        Ok(()) => {
            let mut db_conn = get_db_conn(&conn)?;
            activity_logger::log_user_event(
                &mut db_conn,
                _identity.as_ref(),
                "Deleted user",
                &username_for_log,
            );
            Ok(HttpResponse::Ok().json(ApiResponse::success_message("User deleted successfully".to_string())))
        },
        Err(e) => internal_error_response(e),
    }
}

#[derive(Serialize, Deserialize, Debug, ToSchema)]
pub struct UserKeyResponse {
    pub id: i32,
    pub key_type: String,
    pub key_base64: String,
    pub key_name: Option<String>,
    pub extra_comment: Option<String>,
    pub fingerprint: Option<String>,
}

#[derive(Serialize, Deserialize, Debug, ToSchema)]
pub struct UserKeysResponse {
    pub keys: Vec<UserKeyResponse>,
}

/// Get SSH keys for a user
#[utoipa::path(
    get,
    path = "/api/user/{username}/keys",
    security(
        ("session_auth" = [])
    ),
    params(
        ("username" = String, Path, description = "Username")
    ),
    responses(
        (status = 200, description = "User SSH keys", body = UserKeysResponse),
        (status = 404, description = "User not found", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[get("/{username}/keys")]
async fn get_user_keys(
    conn: Data<ConnectionPool>,
    username: Path<String>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let conn_clone = conn.clone();
    let username_str = username.to_string();
    let maybe_user_keys = web::block(move || {
        let mut connection = get_db_conn_string(&conn_clone)?;
        let user = User::get_user(&mut connection, username_str)?;
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
                        key_name: key.name,
                        extra_comment: key.extra_comment,
                        fingerprint,
                    }
                })
                .collect();
            Ok(HttpResponse::Ok().json(ApiResponse::success(UserKeysResponse { keys: key_responses })))
        }
        Err(error) => internal_error_response(error),
    }
}

#[derive(Serialize, Deserialize, Debug, ToSchema)]
pub struct UserAuthorizationsResponse {
    pub authorizations: Vec<UserAndOptions>,
}

/// Get user authorizations (hosts they can access)
#[utoipa::path(
    get,
    path = "/api/user/{username}/authorizations",
    security(
        ("session_auth" = [])
    ),
    params(
        ("username" = String, Path, description = "Username")
    ),
    responses(
        (status = 200, description = "User authorizations", body = UserAuthorizationsResponse),
        (status = 404, description = "User not found", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[get("/{username}/authorizations")]
async fn get_user_authorizations(
    conn: Data<ConnectionPool>,
    username: Path<String>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let conn_clone = conn.clone();
    let username_str = username.to_string();
    let maybe_user_auth = web::block(move || {
        let mut connection = get_db_conn_string(&conn_clone)?;
        let user = User::get_user(&mut connection, username_str)?;
        user.get_authorizations(&mut connection)
    })
    .await?;

    match maybe_user_auth {
        Ok(authorizations) => Ok(HttpResponse::Ok().json(ApiResponse::success(UserAuthorizationsResponse { authorizations }))),
        Err(error) => internal_error_response(error),
    }
}

#[derive(Deserialize, ToSchema)]
pub struct AssignKeyRequest {
    user_id: i32,
    key_type: String,
    key_base64: String,
    key_name: Option<String>,
    extra_comment: Option<String>,
}

/// Assign an SSH key to a user
#[utoipa::path(
    post,
    path = "/api/user/assign_key",
    security(
        ("session_auth" = [])
    ),
    request_body = AssignKeyRequest,
    responses(
        (status = 201, description = "Key assigned successfully"),
        (status = 400, description = "Invalid key algorithm", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[post("/assign_key")]
async fn assign_key_to_user(
    conn: Data<ConnectionPool>,
    json: Json<AssignKeyRequest>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    // Validate that the key type is valid
    let algorithm = match russh::keys::Algorithm::new(&json.key_type) {
        Ok(algo) => algo,
        Err(_) => {
            return bad_request_response("Invalid key algorithm".to_string());
        }
    };

    let new_key = NewPublicUserKey::new(
        algorithm,
        json.key_base64.clone(),
        json.key_name.clone(),
        json.extra_comment.clone(),
        json.user_id,
    );

    let conn_clone = conn.clone();
    let user_id_for_log = json.user_id;
    let res = web::block(move || {
        let mut db_conn = get_db_conn_string(&conn_clone)?;
        PublicUserKey::add_key(&mut db_conn, new_key)
    }).await?;

    match res {
        Ok(()) => {
            let mut db_conn = get_db_conn(&conn)?;
            activity_logger::log_key_event(
                &mut db_conn,
                _identity.as_ref(),
                "Assigned key to user",
                &format!("User ID {}", user_id_for_log),
            );
            Ok(HttpResponse::Created().json(ApiResponse::success_message("Key assigned successfully".to_string())))
        },
        Err(e) => internal_error_response(e),
    }
}

#[derive(Deserialize, ToSchema)]
pub struct UpdateUserRequest {
    username: String,
    enabled: bool,
    comment: Option<String>,
}

/// Update a user's information
#[utoipa::path(
    put,
    path = "/api/user/{old_username}",
    security(
        ("session_auth" = [])
    ),
    params(
        ("old_username" = String, Path, description = "Current username")
    ),
    request_body = UpdateUserRequest,
    responses(
        (status = 200, description = "User updated successfully"),
        (status = 400, description = "Bad request", body = ApiError),
        (status = 401, description = "Unauthorized - authentication required", body = ApiError)
    )
)]
#[put("/{old_username}")]
async fn update_user(
    conn: Data<ConnectionPool>,
    old_username: Path<String>,
    json: Json<UpdateUserRequest>,
    _identity: Option<Identity>,
) -> Result<impl Responder> {
    let mut db_conn = get_db_conn(&conn)?;
    
    // Fetch the old user to track changes
    let old_user = User::get_user(&mut db_conn, old_username.to_string())
        .map_err(|_| actix_web::error::ErrorNotFound("User not found"))?;
    
    // Track changes for metadata
    let mut changes = serde_json::Map::new();
    
    if old_user.username != json.username {
        changes.insert("username".to_string(), serde_json::json!({
            "old": old_user.username,
            "new": json.username
        }));
    }
    if old_user.enabled != json.enabled {
        changes.insert("enabled".to_string(), serde_json::json!({
            "old": old_user.enabled,
            "new": json.enabled
        }));
    }
    if old_user.comment != json.comment {
        changes.insert("comment".to_string(), serde_json::json!({
            "old": old_user.comment,
            "new": json.comment
        }));
    }
    
    match User::update_user(
        &mut db_conn,
        &old_username,
        &json.username,
        json.enabled,
        json.comment.clone(),
    ) {
        Ok(_) => {
            // Log activity with changes metadata
            let metadata = if !changes.is_empty() {
                Some(serde_json::to_string(&changes).unwrap_or_default())
            } else {
                None
            };
            
            if let Err(e) = crate::routes::activity_log::log_activity(
                &mut db_conn,
                "user",
                "Updated user",
                &json.username,
                &crate::activity_logger::extract_username(_identity.as_ref()),
                metadata,
            ) {
                log::error!("Failed to log user update activity: {}", e);
            }
            
            Ok(HttpResponse::Ok().json(ApiResponse::success_message("User updated successfully".to_string())))
        },
        Err(error) => internal_error_response(error),
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
    path = "/api/user/add_key",
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
