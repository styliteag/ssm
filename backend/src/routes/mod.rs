pub mod authentication;
pub mod authorization;
pub mod diff;
pub mod host;
pub mod key;
pub mod user;
pub mod activity_log;

use actix_web::{
    get,
    web::{self, Data},
    HttpResponse, Responder, Result,
};
use utoipa::{OpenApi, ToSchema};
use serde::Serialize;
use crate::api_types::*;
use crate::ConnectionPool;
use diesel::r2d2::{PooledConnection, ConnectionManager};
use crate::DbConnection;



pub fn route_config(cfg: &mut web::ServiceConfig) {
    cfg.service(api_info)
        .service(health)
        .service(openapi_json)
        .service(crate::openapi::swagger_ui())
        .service(
            web::scope("/api")
                .service(api_info_scoped)
                .service(web::scope("/host").configure(host::config))
                .service(web::scope("/user").configure(user::config))
                .service(web::scope("/key").configure(key::config))
                .service(web::scope("/diff").configure(diff::config))
                .service(web::scope("/auth").configure(authentication::config))
                .service(web::scope("/authorization").configure(authorization::config))
                .configure(activity_log::configure)
        )
        .default_service(web::to(not_found));
}

/// Standardized error handling helpers for route handlers

/// Internal helper function that performs the actual database connection retrieval
/// This is the single source of truth for connection error handling
/// Returns the raw error from the pool
fn get_db_conn_internal(
    pool: &ConnectionPool,
) -> Result<PooledConnection<ConnectionManager<DbConnection>>, impl std::error::Error + Send + Sync> {
    pool.get()
}

/// Get a database connection from the pool, returning a standardized error
/// Use this for direct database access in route handlers
pub fn get_db_conn(
    pool: &Data<ConnectionPool>,
) -> Result<PooledConnection<ConnectionManager<DbConnection>>, actix_web::Error> {
    get_db_conn_internal(pool.get_ref()).map_err(|e| {
        log::error!("Database connection error: {}", e);
        actix_web::error::ErrorInternalServerError(format!("Database connection error: {}", e))
    })
}

/// Get a database connection from the pool for use in web::block closures
/// Returns String error for compatibility with web::block error handling
/// 
/// Note: This function exists because web::block closures need to move the ConnectionPool,
/// and Data<ConnectionPool> cannot be moved (it's not Send). Use this version when
/// passing &ConnectionPool directly to web::block closures.
pub fn get_db_conn_string(
    pool: &ConnectionPool,
) -> Result<PooledConnection<ConnectionManager<DbConnection>>, String> {
    get_db_conn_internal(pool).map_err(|e| {
        log::error!("Database connection error: {}", e);
        format!("Database connection error: {}", e)
    })
}


/// Standardized error response for internal server errors
pub fn internal_error_response(error: impl std::fmt::Display) -> Result<HttpResponse, actix_web::Error> {
    log::error!("Internal server error: {}", error);
    Ok(HttpResponse::InternalServerError().json(ApiError::internal_error(error.to_string())))
}

/// Standardized error response for not found errors
pub fn not_found_response(message: String) -> Result<HttpResponse, actix_web::Error> {
    log::warn!("Resource not found: {}", message);
    Ok(HttpResponse::NotFound().json(ApiError::not_found(message)))
}

/// Standardized error response for bad request errors
pub fn bad_request_response(message: String) -> Result<HttpResponse, actix_web::Error> {
    log::warn!("Bad request: {}", message);
    Ok(HttpResponse::BadRequest().json(ApiError::bad_request(message)))
}

#[derive(Serialize, ToSchema)]
pub struct ApiInfo {
    pub name: String,
    pub version: String,
    pub description: String,
}


async fn not_found() -> Result<impl Responder> {
    Ok(HttpResponse::NotFound().json(ApiError::not_found("Endpoint not found".to_string())))
}

/// Get API information
#[utoipa::path(
    get,
    path = "/",
    responses(
        (status = 200, description = "API information", body = ApiInfo)
    )
)]
#[get("/")]
async fn api_info() -> Result<impl Responder> {
    Ok(HttpResponse::Ok().json(ApiResponse::success(ApiInfo {
        name: "SSH Key Manager API".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        description: "REST API for managing SSH keys across multiple hosts".to_string(),
    })))
}

/// Get API information (scoped under /api)
#[utoipa::path(
    get,
    path = "/api/info",
    responses(
        (status = 200, description = "API information", body = ApiInfo)
    )
)]
#[get("/info")]
async fn api_info_scoped() -> Result<impl Responder> {
    Ok(HttpResponse::Ok().json(ApiResponse::success(ApiInfo {
        name: "SSH Key Manager API".to_string(),
        version: env!("CARGO_PKG_VERSION").to_string(),
        description: "REST API for managing SSH keys across multiple hosts".to_string(),
    })))
}

/// Health check endpoint for load balancers and monitoring
#[utoipa::path(
    get,
    path = "/health",
    responses(
        (status = 200, description = "Service healthy")
    )
)]
#[get("/health")]
async fn health() -> Result<impl Responder> {
    Ok(HttpResponse::Ok().json(ApiResponse::success_message("ok".to_string())))
}

/// Serve the OpenAPI specification as JSON
#[utoipa::path(
    get,
    path = "/api-docs/openapi.json",
    responses(
        (status = 200, description = "OpenAPI 3.0 specification in JSON format", content_type = "application/json")
    )
)]
#[get("/api-docs/openapi.json")]
async fn openapi_json() -> Result<impl Responder> {
    Ok(HttpResponse::Ok()
        .content_type("application/json")
        .json(crate::openapi::ApiDoc::openapi()))
}
