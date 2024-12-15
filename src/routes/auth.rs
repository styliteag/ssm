use actix_identity::Identity;
use actix_web::{
    get, post,
    web::{self, Data, Form},
    HttpResponse, Responder, HttpRequest, HttpMessage,
};
use askama_actix::{Template, TemplateToResponse};
use serde::Deserialize;

use crate::{
    forms::FormResponseBuilder,
    models::User,
    ConnectionPool,
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

#[get("/login")]
async fn login_page() -> impl Responder {
    LoginTemplate {}.to_response()
}

#[post("/login")]
async fn login(
    req: HttpRequest,
    form: Form<LoginForm>,
    pool: Data<ConnectionPool>,
) -> actix_web::Result<impl Responder> {
    // Check for hardcoded admin credentials
    let is_valid = form.username == "admin" && form.password == "pass";

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
