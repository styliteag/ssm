use actix_cors::Cors;
use actix_identity::IdentityMiddleware;
use actix_session::{storage::CookieSessionStore, SessionMiddleware};
use actix_web::{
    http::header,
    middleware::Logger,
    web::{self, Data},
    App, HttpServer,
};
use cookie::Key;

use crate::config::Configuration;
use crate::ConnectionPool;
use crate::ssh::{CachingSshClient, SshClient};

fn create_cors() -> Cors {
    Cors::default()
        .allowed_origin_fn(|origin, _req_head| {
            // Allow localhost development origins - return the specific origin, not "*"
            // This fixes login functionality when credentials are included
            if let Ok(origin_str) = origin.to_str() {
                origin_str.starts_with("http://localhost:")
                    || origin_str.starts_with("https://localhost:")
                    || origin_str.starts_with("http://127.0.0.1:")
                    || origin_str.starts_with("https://127.0.0.1:")
            } else {
                false
            }
        })
        .allowed_methods(vec!["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"])
        .allowed_headers(vec![
            header::AUTHORIZATION,
            header::ACCEPT,
            header::CONTENT_TYPE,
            actix_web::http::header::HeaderName::from_static("x-csrf-token"),
        ])
        .supports_credentials()
}

pub async fn start_server(
    configuration: &Configuration,
    pool: ConnectionPool,
    ssh_client: Data<SshClient>,
    caching_ssh_client: Data<CachingSshClient>,
    config: Data<Configuration>,
    secret_key: Key,
) -> std::io::Result<()> {
    let listen = configuration.listen;
    let port = configuration.port;
    
    let server = HttpServer::new(move || {
        let cors = create_cors();

        App::new()
            .wrap(cors)
            .wrap(Logger::new("%a \"%r\" %s %b \"%{Referer}i\" \"%{User-Agent}i\" %T"))
            .wrap(crate::middleware::CsrfProtection)      // Outermost - runs first
            .wrap(crate::middleware::AuthEnforcement)     // Enforce authentication by default
            .wrap(IdentityMiddleware::default())   // Identity middleware needs to run before our auth middleware
            .wrap(
                SessionMiddleware::builder(CookieSessionStore::default(), secret_key.clone())
                    .cookie_name("ssm_session".to_owned())
                    .cookie_secure(std::env::var("HTTPS_ENABLED").is_ok()) // Only secure in HTTPS mode
                    .cookie_http_only(true)
                    .cookie_same_site(actix_web::cookie::SameSite::Lax)
                    .build(),
            )
            .app_data(ssh_client.clone())
            .app_data(caching_ssh_client.clone())
            .app_data(config.clone())
            .app_data(web::Data::new(pool.clone()))
            .configure(crate::routes::route_config)
    })
    .bind((listen, port))?
    .run();

    log::info!("Server started successfully on {}:{}", configuration.listen, configuration.port);

    let result = server.await;

    // Log shutdown based on the result
    match &result {
        Ok(()) => {
            crate::logging::AppLogger::log_shutdown("ssm", "server completed normally");
        }
        Err(e) => {
            crate::logging::AppLogger::log_shutdown("ssm", &format!("server error: {}", e));
        }
    }

    result
}

