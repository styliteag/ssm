use actix_identity::Identity;
use actix_web::{
    get, post,
    web::{self, Data, Json},
    HttpMessage, HttpRequest, HttpResponse, Responder, Result,
};
use bcrypt::{verify, BcryptError};
use log::error;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;
use std::fs;

use crate::{Configuration, api_types::*};

#[derive(Deserialize, ToSchema)]
pub struct LoginRequest {
    username: String,
    password: String,
}

#[derive(Serialize, ToSchema)]
pub struct LoginResponse {
    pub success: bool,
    pub username: String,
    pub message: String,
}

#[derive(Serialize, ToSchema)]
pub struct StatusResponse {
    pub logged_in: bool,
    pub username: Option<String>,
}

fn verify_apache_password(password: &str, hash: &str) -> Result<bool, BcryptError> {
    // Apache htpasswd bcrypt format starts with $2y$

    match &hash[..4] {
        "$2y$" => {
            let converted_hash = format!("$2b${}", &hash[4..]);
            verify(password, &converted_hash)
        }
        "$2b$" => verify(password, hash),
        hash_type => {
            error!("Unsupported hash type '{hash_type}' encountered.");
            Ok(false)
        }
    }
}


/// User login with credentials
#[utoipa::path(
    post,
    path = "/api/auth/login",
    request_body = LoginRequest,
    responses(
        (status = 200, description = "Login successful", body = LoginResponse),
        (status = 401, description = "Invalid credentials", body = ApiError)
    )
)]
#[post("/login")]
async fn login(
    req: HttpRequest,
    json: Json<LoginRequest>,
    config: Data<Configuration>,
) -> Result<impl Responder> {
    let htpasswd_path = config.htpasswd_path.as_path();

    // Check if password file exists
    if !htpasswd_path.exists() {
        error!("Authentication file not found");
        return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(
            "Authentication file not found".to_string(),
        )));
    }

    // Read and verify credentials from password file
    let password_file = match fs::read_to_string(htpasswd_path) {
        Ok(content) => content,
        Err(e) => {
            error!("Error reading authentication file: {e}");
            return Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(
                "Error reading authentication file".to_string(),
            )));
        }
    };

    let mut is_valid = false;
    for line in password_file.lines() {
        if let Some((username, hash)) = line.split_once(':') {
            if username == json.username {
                match verify_apache_password(&json.password, hash) {
                    Ok(valid) => {
                        is_valid = valid;
                        break;
                    }
                    Err(_) => continue,
                }
            }
        }
    }

    if is_valid {
        Identity::login(&req.extensions(), json.username.clone())
            .map_err(actix_web::error::ErrorInternalServerError)?;
        Ok(HttpResponse::Ok().json(ApiResponse::success(LoginResponse {
            success: true,
            username: json.username.clone(),
            message: "Login successful".to_string(),
        })))
    } else {
        Ok(HttpResponse::Unauthorized().json(ApiError::new(
            "Invalid username or password".to_string(),
        )))
    }
}

/// User logout
#[utoipa::path(
    post,
    path = "/api/auth/logout",
    responses(
        (status = 200, description = "Logout successful")
    )
)]
#[post("/logout")]
async fn logout(identity: Identity) -> impl Responder {
    identity.logout();
    HttpResponse::Ok().json(ApiResponse::success_message(
        "Logged out successfully".to_string(),
    ))
}

/// Get authentication status
#[utoipa::path(
    get,
    path = "/api/auth/status",
    responses(
        (status = 200, description = "Authentication status", body = StatusResponse)
    )
)]
#[get("/status")]
async fn auth_status(identity: Option<Identity>) -> impl Responder {
    let username = identity.as_ref().and_then(|id| id.id().ok());
    HttpResponse::Ok().json(ApiResponse::success(StatusResponse {
        logged_in: identity.is_some(),
        username,
    }))
}

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(login)
        .service(logout)
        .service(auth_status);
}
