use actix_identity::Identity;
use actix_web::{
    get, post,
    web::{self, Data, Form},
    HttpMessage, HttpRequest, HttpResponse, Responder,
};
use askama_actix::{Template, TemplateToResponse};
use bcrypt::{verify, BcryptError};
use log::error;
use serde::Deserialize;
use std::fs;

use crate::{Configuration, ConnectionPool};

use super::ErrorTemplate;

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
        error!("Authentication file not found");
        return Ok(ErrorTemplate {
            error: "Authentication file not found".to_owned(),
        }
        .to_response());
    }

    // Read and verify credentials from password file
    let password_file = match fs::read_to_string(htpasswd_path) {
        Ok(content) => content,
        Err(e) => {
            error!("Error reading authentication file: {e}");
            return Ok(ErrorTemplate {
                error: "Error reading authentication file".to_owned(),
            }
            .to_response());
        }
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
        Ok(ErrorTemplate {
            error: "Invalid credentials".to_owned(),
        }
        .to_response())
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
