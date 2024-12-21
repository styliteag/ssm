use actix_identity::Identity;
use actix_web::{
    get, post,
    web::{self, Data, Form},
    HttpResponse, Responder, HttpRequest, HttpMessage,
};
use askama_actix::{Template, TemplateToResponse};
use serde::Deserialize;
use bcrypt::{verify, BcryptError};
use std::fs;

use crate::{
    forms::FormResponseBuilder,
    ConnectionPool,
    Configuration,
};

#[derive(Template)]
#[template(path = "auth/login.html")]
struct LoginTemplate {}

#[derive(Template)]
#[template(path = "auth/status.html")]
struct StatusTemplate {
    logged_in: bool,
}

#[derive(Deserialize)]
pub struct LoginForm {
    username: String,
    password: String,
}

fn verify_apache_password(password: &str, hash: &str) -> Result<bool, BcryptError> {
    // Apache htpasswd bcrypt format starts with $2y$
    if hash.starts_with("$2y$") {
        // bcrypt crate uses $2b$ format, so we need to convert
        let converted_hash = "$2b$".to_string() + &hash[4..];
        verify(password, &converted_hash)
    } else if hash.starts_with("$2b$") {
        // Already in the correct format
        verify(password, hash)
    } else {
        // Unsupported hash format
        Ok(false)
    }
}

#[get("/login")]
async fn login_page() -> impl Responder {
    LoginTemplate {}.to_response()
}

#[post("/login")]
async fn login(
    req: HttpRequest,
    form: Form<LoginForm>,
    _pool: Data<ConnectionPool>,
    config: Data<Configuration>,
) -> actix_web::Result<impl Responder> {
    let htpasswd_path = config.htpasswd_path.as_path();
    
    // Check if password file exists
    if !htpasswd_path.exists() {
        return Ok(FormResponseBuilder::error("Authentication file not found".to_string()).into_response());
    }

    // Read and verify credentials from password file
    let password_file = match fs::read_to_string(htpasswd_path) {
        Ok(content) => content,
        Err(_) => return Ok(FormResponseBuilder::error("Error reading authentication file".to_string()).into_response()),
    };

    let mut is_valid = false;
    for line in password_file.lines() {
        if let Some((username, hash)) = line.split_once(':') {
            if username == form.username {
                match verify_apache_password(&form.password, hash) {
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
        Identity::login(&req.extensions(), form.username.clone())
            .map_err(actix_web::error::ErrorInternalServerError)?;
        Ok(HttpResponse::Found()
            .insert_header(("Location", "/"))
            .finish())
    } else {
        Ok(FormResponseBuilder::error("Invalid credentials".to_string()).into_response())
    }
}

#[post("/logout")]
async fn logout(identity: Identity) -> impl Responder {
    identity.logout();
    HttpResponse::Ok()
        .insert_header(("HX-Redirect", "/auth/login"))
        .body("<a href=\"/auth/login\">Login</a>")
}

#[get("/status")]
async fn auth_status(identity: Option<Identity>) -> impl Responder {
    StatusTemplate {
        logged_in: identity.is_some(),
    }
    .to_response()
}

pub fn auth_config(cfg: &mut web::ServiceConfig) {
    cfg.service(login_page)
        .service(login)
        .service(logout)
        .service(auth_status);
}
