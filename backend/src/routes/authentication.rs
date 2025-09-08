use actix_identity::Identity;
use actix_session::Session;
use actix_web::{
    get, options, post,
    web::{self, Data, Json},
    HttpMessage, HttpRequest, HttpResponse, Responder, Result,
};
use bcrypt::{verify, BcryptError};
use log::error;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;
use std::fs;
use base64::{engine::general_purpose::STANDARD, Engine};
use rand::Rng;

use crate::{Configuration, api_types::*, logging::{AuthLogger, SecurityLogger}};

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
    pub csrf_token: String,
}

#[derive(Serialize, ToSchema)]
pub struct StatusResponse {
    pub logged_in: bool,
    pub username: Option<String>,
}

#[derive(Serialize, ToSchema)]
pub struct CsrfTokenResponse {
    pub csrf_token: String,
}

fn generate_csrf_token() -> String {
    let mut rng = rand::thread_rng();
    let token_bytes: [u8; 32] = rng.gen();
    STANDARD.encode(token_bytes)
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
    session: Session,
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

        // Generate and store CSRF token in session
        let csrf_token = generate_csrf_token();
        session.insert("csrf_token", &csrf_token)
            .map_err(actix_web::error::ErrorInternalServerError)?;

        AuthLogger::log_auth_success(&json.username, "password");
        AuthLogger::log_session_event("created", "session_id_placeholder");

        Ok(HttpResponse::Ok().json(ApiResponse::success(LoginResponse {
            success: true,
            username: json.username.clone(),
            message: "Login successful".to_string(),
            csrf_token,
        })))
    } else {
        AuthLogger::log_auth_failure(Some(&json.username), "password", "invalid_credentials");

        // Log suspicious activity for potential brute force attempts
        SecurityLogger::log_security_event(
            "authentication_failure",
            &format!("Failed login attempt for user: {}", json.username),
            "medium"
        );

        // Log suspicious activity with IP address for monitoring
        let connection_info = req.connection_info();
        let client_ip = connection_info.peer_addr().unwrap_or("unknown").to_string();
        SecurityLogger::log_suspicious_activity(
            "failed_login_attempt",
            &client_ip,
            &format!("Failed authentication attempt for user '{}' from IP {}", json.username, client_ip)
        );

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
async fn logout(identity: Option<Identity>, session: Session) -> impl Responder {
    if let Some(id) = identity {
        id.logout();
        // Clear CSRF token from session
        session.remove("csrf_token");
    }
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

/// Get current CSRF token
#[utoipa::path(
    get,
    path = "/api/auth/csrf",
    responses(
        (status = 200, description = "CSRF token", body = CsrfTokenResponse),
        (status = 401, description = "Not authenticated", body = ApiError)
    )
)]
#[get("/csrf")]
async fn get_csrf_token(identity: Option<Identity>, session: Session) -> Result<impl Responder> {
    if identity.is_none() {
        return Ok(HttpResponse::Unauthorized().json(ApiError::unauthorized()));
    }
    
    // Get existing token or generate a new one
    let csrf_token = if let Ok(Some(token)) = session.get::<String>("csrf_token") {
        token
    } else {
        let new_token = generate_csrf_token();
        session.insert("csrf_token", &new_token)
            .map_err(actix_web::error::ErrorInternalServerError)?;
        new_token
    };
    
    Ok(HttpResponse::Ok().json(ApiResponse::success(CsrfTokenResponse {
        csrf_token,
    })))
}

/// Handle OPTIONS requests for CORS preflight
#[options("/{path:.*}")]
async fn handle_options(req: HttpRequest) -> impl Responder {
    // Get the origin from the request headers
    let origin = req.headers()
        .get("origin")
        .and_then(|h| h.to_str().ok())
        .unwrap_or("http://localhost:5173");

    HttpResponse::Ok()
        .insert_header(("Access-Control-Allow-Origin", origin))
        .insert_header(("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS"))
        .insert_header(("Access-Control-Allow-Headers", "Content-Type, Authorization, X-CSRF-Token"))
        .insert_header(("Access-Control-Allow-Credentials", "true"))
        .insert_header(("Access-Control-Max-Age", "3600"))
        .finish()
}

pub fn config(cfg: &mut web::ServiceConfig) {
    cfg.service(login)
        .service(logout)
        .service(auth_status)
        .service(get_csrf_token)
        .service(handle_options);
}
