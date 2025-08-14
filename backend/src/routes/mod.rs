mod authentication;
mod authorization;
mod diff;
mod host;
mod key;
mod user;

use actix_web::{
    get,
    web::{self},
    HttpResponse, Responder, Result,
};
use serde::{Deserialize, Serialize};

use crate::api_types::*;

pub fn route_config(cfg: &mut web::ServiceConfig) {
    cfg.service(api_info)
        .service(
            web::scope("/api")
                .service(web::scope("/host").configure(host::config))
                .service(web::scope("/user").configure(user::config))
                .service(web::scope("/key").configure(key::config))
                .service(web::scope("/diff").configure(diff::config))
                .service(web::scope("/auth").configure(authentication::config))
                .service(web::scope("/authorization").configure(authorization::config))
        )
        .default_service(web::to(not_found));
}

#[derive(Deserialize)]
struct ForceUpdateQuery {
    force_update: Option<bool>,
}

#[allow(dead_code)]
type ForceUpdate = web::Query<ForceUpdateQuery>;

#[allow(dead_code)]
fn should_update(force_update: ForceUpdate) -> bool {
    force_update.force_update.is_some_and(|update| update)
}

#[derive(Serialize)]
struct ApiInfo {
    name: String,
    version: String,
    description: String,
}


async fn not_found() -> Result<impl Responder> {
    Ok(HttpResponse::NotFound().json(ApiError::not_found("Endpoint not found".to_string())))
}

#[get("/")]
async fn api_info() -> Result<impl Responder> {
    Ok(HttpResponse::Ok().json(ApiResponse::success(ApiInfo {
        name: "SSH Key Manager API".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        description: "REST API for managing SSH keys across multiple hosts".to_string(),
    })))
}
