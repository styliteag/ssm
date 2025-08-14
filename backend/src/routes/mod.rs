mod authentication;
mod authorization;
mod diff;
mod host;
mod key;
mod user;

use actix_web::{
    get,
    http::StatusCode,
    web::{self},
    Responder,
};
use askama_actix::Template;
use serde::Deserialize;

pub fn route_config(cfg: &mut web::ServiceConfig) {
    cfg.service(index)
        .service(web::scope("/host").configure(host::config))
        .service(web::scope("/user").configure(user::config))
        .service(web::scope("/key").configure(key::config))
        .service(web::scope("/diff").configure(diff::config))
        .service(web::scope("/authentication").configure(authentication::config))
        .service(web::scope("/authorization").configure(authorization::config))
        .default_service(web::to(not_found));
}

#[derive(Deserialize)]
struct ForceUpdateQuery {
    force_update: Option<bool>,
}

type ForceUpdate = web::Query<ForceUpdateQuery>;

fn should_update(force_update: ForceUpdate) -> bool {
    force_update.force_update.is_some_and(|update| update)
}

#[derive(Template)]
#[template(path = "error.html")]
struct ErrorTemplate {
    error: String,
}

#[derive(Template)]
#[template(path = "render/error.html")]
struct RenderErrorTemplate {
    error: String,
}

#[derive(Template)]
#[template(path = "404.html")]
struct NotFoundTemplate {}

async fn not_found() -> impl Responder {
    NotFoundTemplate {}
        .customize()
        .with_status(StatusCode::NOT_FOUND)
}

#[derive(Template)]
#[template(path = "index.html")]
struct IndexTemplate {}

#[get("/")]
async fn index() -> impl Responder {
    IndexTemplate {}
}
